// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import Sodium
import SessionSnodeKit
import SessionUtilitiesKit

public enum PushNotificationAPI {
    internal static let sodium: Atomic<Sodium> = Atomic(Sodium())
    private static let keychainService: String = "PNKeyChainService"
    private static let encryptionKeyKey: String = "PNEncryptionKeyKey"
    private static let encryptionKeyLength: Int = 32
    private static let maxRetryCount: Int = 4
    private static let tokenExpirationInterval: TimeInterval = (12 * 60 * 60)
    
    public static let server = "https://push.getsession.org"
    public static let serverPublicKey = "d7557fe563e2610de876c0ac7341b62f3c82d5eea4b62c702392ea4368f51b3b"
    public static let legacyServer = "https://live.apns.getsession.org"
    public static let legacyServerPublicKey = "642a6585919742e5a2d4dc51244964fbcd8bcab2b75612407de58b810740d049"
        
    // MARK: - Requests
    
    public static func subscribe(
        token: Data,
        isForcedUpdate: Bool,
        using dependencies: SSKDependencies = SSKDependencies()
    ) -> AnyPublisher<Void, Error> {
        let hexEncodedToken: String = token.toHexString()
        let oldToken: String? = UserDefaults.standard[.deviceToken]
        let lastUploadTime: Double = UserDefaults.standard[.lastDeviceTokenUpload]
        let now: TimeInterval = Date().timeIntervalSince1970
        
        guard isForcedUpdate || hexEncodedToken != oldToken || now - lastUploadTime > tokenExpirationInterval else {
            SNLog("Device token hasn't changed or expired; no need to re-upload.")
            return Just(())
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
        
        guard let notificationsEncryptionKey: Data = try? getOrGenerateEncryptionKey() else {
            SNLog("Unable to retrieve PN encryption key.")
            return Just(())
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
        
        // TODO: Need to generate requests for each updated group as well
        return Storage.shared
            .readPublisher { db -> (SubscribeRequest, String, Set<String>) in
                guard let userED25519KeyPair: KeyPair = Identity.fetchUserEd25519KeyPair(db) else {
                    throw SnodeAPIError.noKeyPair
                }
                
                let currentUserPublicKey: String = getUserHexEncodedPublicKey(db)
                let previewType: Preferences.NotificationPreviewType = db[.preferencesNotificationPreviewType]
                    .defaulting(to: Preferences.NotificationPreviewType.defaultPreviewType)
                
                let request: SubscribeRequest = SubscribeRequest(
                    pubkey: currentUserPublicKey,
                    namespaces: [.default],
                    includeMessageData: (previewType == .nameAndPreview), // TODO: Test resubscribing when changing the type
                    serviceInfo: SubscribeRequest.ServiceInfo(
                        token: hexEncodedToken
                    ),
                    notificationsEncryptionKey: notificationsEncryptionKey,
                    subkey: nil,
                    timestamp: (TimeInterval(SnodeAPI.currentOffsetTimestampMs()) / 1000),  // Seconds
                    ed25519PublicKey: userED25519KeyPair.publicKey,
                    ed25519SecretKey: userED25519KeyPair.secretKey
                )
                
                return (
                    request,
                    currentUserPublicKey,
                    try ClosedGroup
                        .select(.threadId)
                        .filter(!ClosedGroup.Columns.threadId.like("\(SessionId.Prefix.group.rawValue)%"))
                        .joining(
                            required: ClosedGroup.members
                                .filter(GroupMember.Columns.profileId == getUserHexEncodedPublicKey(db))
                        )
                        .asRequest(of: String.self)
                        .fetchSet(db)
                )
            }
            .flatMap { request, currentUserPublicKey, legacyGroupIds -> AnyPublisher<Void, Error> in
                Publishers
                    .MergeMany(
                        [
                            PushNotificationAPI
                                .send(
                                    request: PushNotificationAPIRequest(
                                        endpoint: .subscribe,
                                        body: request
                                    )
                                )
                                .decoded(as: SubscribeResponse.self, using: dependencies)
                                .retry(maxRetryCount)
                                .handleEvents(
                                    receiveOutput: { _, response in
                                        guard response.success == true else {
                                            return SNLog("Couldn't subscribe for push notifications due to error (\(response.error ?? -1)): \(response.message ?? "nil").")
                                        }
                                        
                                        UserDefaults.standard[.deviceToken] = hexEncodedToken
                                        UserDefaults.standard[.lastDeviceTokenUpload] = now
                                        UserDefaults.standard[.isUsingFullAPNs] = true
                                    },
                                    receiveCompletion: { result in
                                        switch result {
                                            case .finished: break
                                            case .failure: SNLog("Couldn't subscribe for push notifications.")
                                        }
                                    }
                                )
                                .flatMap { _ in
                                    guard UserDefaults.standard[.hasUnregisteredForLegacyPushNotifications] != true else {
                                        return Just(())
                                            .setFailureType(to: Error.self)
                                            .eraseToAnyPublisher()
                                    }
                                    
                                    return PushNotificationAPI
                                        .send(
                                            request: PushNotificationAPIRequest(
                                                endpoint: .legacyUnregister,
                                                body: LegacyUnsubscribeRequest(
                                                    token: hexEncodedToken
                                                )
                                            )
                                        )
                                        .retry(maxRetryCount)
                                        .handleEvents(
                                            receiveCompletion: { result in
                                                switch result {
                                                    case .finished:
                                                        /// Save that we've already unsubscribed
                                                        ///
                                                        /// **Note:** The server can return an error (`response.code != 0`) but
                                                        /// that means the server properly processed the request and the error is likely
                                                        /// due to the device not actually being previously subscribed for notifications
                                                        /// rather than actually failing to unsubscribe
                                                        UserDefaults.standard[.hasUnregisteredForLegacyPushNotifications] = true
                                                        
                                                    case .failure: SNLog("Couldn't unsubscribe for legacy notifications.")
                                                }
                                            }
                                        )
                                        .map { _ in () }
                                        .eraseToAnyPublisher()
                                }
                                .eraseToAnyPublisher()
                        ].appending(
                            // FIXME: Remove this once legacy groups are deprecated
                            contentsOf: legacyGroupIds
                                .map { legacyGroupId in
                                    PushNotificationAPI.subscribeToLegacyGroup(
                                        legacyGroupId: legacyGroupId,
                                        currentUserPublicKey: currentUserPublicKey,
                                        using: dependencies
                                    )
                                }
                        )
                    )
                    .collect()
                    .map { _ in () }
                    .eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }
    
    public static func unsubscribe(
        token: Data,
        using dependencies: SSKDependencies = SSKDependencies()
    ) -> AnyPublisher<Void, Error> {
        let hexEncodedToken: String = token.toHexString()
        
        // FIXME: Remove this once legacy groups are deprecated
        /// Unsubscribe from all legacy groups (including ones the user is no longer a member of, just in case)
        Storage.shared
            .readPublisher { db -> (String, Set<String>) in
                (
                    getUserHexEncodedPublicKey(db),
                    try ClosedGroup
                        .select(.threadId)
                        .filter(!ClosedGroup.Columns.threadId.like("\(SessionId.Prefix.group.rawValue)%"))
                        .asRequest(of: String.self)
                        .fetchSet(db)
                )
            }
            .flatMap { currentUserPublicKey, legacyGroupIds in
                Publishers
                    .MergeMany(
                        legacyGroupIds
                            .map { legacyGroupId -> AnyPublisher<Void, Error> in
                                PushNotificationAPI
                                    .unsubscribeFromLegacyGroup(
                                        legacyGroupId: legacyGroupId,
                                        currentUserPublicKey: currentUserPublicKey,
                                        using: dependencies
                                    )
                            }
                    )
                    .collect()
                    .eraseToAnyPublisher()
            }
            .subscribe(on: DispatchQueue.global(qos: .userInitiated))
            .sinkUntilComplete()
        
        // TODO: Need to generate requests for each updated group as well
        return Storage.shared
            .readPublisher { db -> UnsubscribeRequest in
                guard let userED25519KeyPair: KeyPair = Identity.fetchUserEd25519KeyPair(db) else {
                    throw SnodeAPIError.noKeyPair
                }
                
                return UnsubscribeRequest(
                    pubkey: getUserHexEncodedPublicKey(db),
                    serviceInfo: UnsubscribeRequest.ServiceInfo(
                        token: hexEncodedToken
                    ),
                    subkey: nil,
                    timestamp: (TimeInterval(SnodeAPI.currentOffsetTimestampMs()) / 1000),  // Seconds
                    ed25519PublicKey: userED25519KeyPair.publicKey,
                    ed25519SecretKey: userED25519KeyPair.secretKey
                )
            }
            .flatMap { request -> AnyPublisher<Void, Error> in
                PushNotificationAPI
                    .send(
                        request: PushNotificationAPIRequest(
                            endpoint: .unsubscribe,
                            body: request
                        )
                    )
                    .decoded(as: UnsubscribeResponse.self, using: dependencies)
                    .retry(maxRetryCount)
                    .handleEvents(
                        receiveOutput: { _, response in
                            guard response.success == true else {
                                return SNLog("Couldn't unsubscribe for push notifications due to error (\(response.error ?? -1)): \(response.message ?? "nil").")
                            }
                            
                            UserDefaults.standard[.deviceToken] = nil
                        },
                        receiveCompletion: { result in
                            switch result {
                                case .finished: break
                                case .failure: SNLog("Couldn't unsubscribe for push notifications.")
                            }
                        }
                    )
                    .map { _ in () }
                    .eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }
    
    // MARK: - Legacy Notifications
    
    // FIXME: Remove this once legacy notifications and legacy groups are deprecated
    public static func legacyNotify(
        recipient: String,
        with message: String,
        maxRetryCount: Int? = nil,
        using dependencies: SSKDependencies = SSKDependencies()
    ) -> AnyPublisher<Void, Error> {
        return PushNotificationAPI
            .send(
                request: PushNotificationAPIRequest(
                    endpoint: .legacyNotify,
                    body: LegacyNotifyRequest(
                        data: message,
                        sendTo: recipient
                    )
                )
            )
            .decoded(as: LegacyPushServerResponse.self, using: dependencies)
            .retry(maxRetryCount ?? PushNotificationAPI.maxRetryCount)
            .handleEvents(
                receiveOutput: { _, response in
                    guard response.code != 0 else {
                        return SNLog("Couldn't send push notification due to error: \(response.message ?? "nil").")
                    }
                },
                receiveCompletion: { result in
                    switch result {
                        case .finished: break
                        case .failure: SNLog("Couldn't send push notification.")
                    }
                }
            )
            .map { _ in () }
            .eraseToAnyPublisher()
    }
    
    // MARK: - Legacy Groups
    
    // FIXME: Remove this once legacy groups are deprecated
    public static func subscribeToLegacyGroup(
        legacyGroupId: String,
        currentUserPublicKey: String,
        using dependencies: SSKDependencies = SSKDependencies()
    ) -> AnyPublisher<Void, Error> {
        let isUsingFullAPNs = UserDefaults.standard[.isUsingFullAPNs]
        
        guard isUsingFullAPNs else {
            return Just(())
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
        
        return PushNotificationAPI
            .send(
                request: PushNotificationAPIRequest(
                    endpoint: .legacyGroupSubscribe,
                    body: LegacyGroupRequest(
                        pubKey: currentUserPublicKey,
                        closedGroupPublicKey: legacyGroupId
                    )
                )
            )
            .decoded(as: LegacyPushServerResponse.self, using: dependencies)
            .retry(maxRetryCount)
            .handleEvents(
                receiveOutput: { _, response in
                    guard response.code != 0 else {
                        return SNLog("Couldn't subscribe for legacy group: \(legacyGroupId) due to error: \(response.message ?? "nil").")
                    }
                },
                receiveCompletion: { result in
                    switch result {
                        case .finished: break
                        case .failure: SNLog("Couldn't subscribe for legacy group: \(legacyGroupId).")
                    }
                }
            )
            .map { _ in () }
            .eraseToAnyPublisher()
    }
    
    // FIXME: Remove this once legacy groups are deprecated
    public static func unsubscribeFromLegacyGroup(
        legacyGroupId: String,
        currentUserPublicKey: String,
        using dependencies: SSKDependencies = SSKDependencies()
    ) -> AnyPublisher<Void, Error> {
        let isUsingFullAPNs = UserDefaults.standard[.isUsingFullAPNs]
        
        // TODO: Need to validate if this is actually desired behaviour - would this check prevent the app from unsubscribing if the user switches off fast mode??? (this is what the app is currently doing)
        // TODO: This flag seems like it might actually be buggy... should double check it
        guard isUsingFullAPNs else {
            return Just(())
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
        
        return PushNotificationAPI
            .send(
                request: PushNotificationAPIRequest(
                    endpoint: .legacyGroupUnsubscribe,
                    body: LegacyGroupRequest(
                        pubKey: currentUserPublicKey,
                        closedGroupPublicKey: legacyGroupId
                    )
                )
            )
            .decoded(as: LegacyPushServerResponse.self, using: dependencies)
            .retry(maxRetryCount)
            .handleEvents(
                receiveOutput: { _, response in
                    guard response.code != 0 else {
                        return SNLog("Couldn't unsubscribe for legacy group: \(legacyGroupId) due to error: \(response.message ?? "nil").")
                    }
                },
                receiveCompletion: { result in
                    switch result {
                        case .finished: break
                        case .failure: SNLog("Couldn't unsubscribe for legacy group: \(legacyGroupId).")
                    }
                }
            )
            .map { _ in () }
            .eraseToAnyPublisher()
    }
                        
    // MARK: - Security
    
    @discardableResult private static func getOrGenerateEncryptionKey() throws -> Data {
        // TODO: May want to work this differently (will break after a phone restart if the device hasn't been unlocked yet)
        do {
            var encryptionKey: Data = try SSKDefaultKeychainStorage.shared.data(
                forService: keychainService,
                key: encryptionKeyKey
            )
            defer { encryptionKey.resetBytes(in: 0..<encryptionKey.count) }
            
            guard encryptionKey.count == encryptionKeyLength else { throw StorageError.invalidKeySpec }
            
            return encryptionKey
        }
        catch {
            switch (error, (error as? KeychainStorageError)?.code) {
                case (StorageError.invalidKeySpec, _), (_, errSecItemNotFound):
                    // No keySpec was found so we need to generate a new one
                    do {
                        var keySpec: Data = try Randomness.generateRandomBytes(numberBytes: encryptionKeyLength)
                        defer { keySpec.resetBytes(in: 0..<keySpec.count) } // Reset content immediately after use
                        
                        try SSKDefaultKeychainStorage.shared.set(
                            data: keySpec,
                            service: keychainService,
                            key: encryptionKeyKey
                        )
                        return keySpec
                    }
                    catch {
                        SNLog("Setting keychain value failed with error: \(error.localizedDescription)")
                        throw StorageError.keySpecCreationFailed
                    }
                    
                default:
                    // Because we use kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, the keychain will be inaccessible
                    // after device restart until device is unlocked for the first time. If the app receives a push
                    // notification, we won't be able to access the keychain to process that notification, so we should
                    // just terminate by throwing an uncaught exception
                    if CurrentAppContext().isMainApp || CurrentAppContext().isInBackground() {
                        let appState: UIApplication.State = CurrentAppContext().reportedApplicationState
                        SNLog("CipherKeySpec inaccessible. New install or no unlock since device restart?, ApplicationState: \(NSStringForUIApplicationState(appState))")
                        throw StorageError.keySpecInaccessible
                    }
                    
                    SNLog("CipherKeySpec inaccessible; not main app.")
                    throw StorageError.keySpecInaccessible
            }
        }
    }
                        
    // MARK: - Convenience
    
    private static func send<T: Encodable>(
        request: PushNotificationAPIRequest<T>,
        using dependencies: SSKDependencies = SSKDependencies()
    ) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
        guard
            let url: URL = URL(string: "\(request.endpoint.server)/\(request.endpoint.rawValue)"),
            let payload: Data = try? JSONEncoder().encode(request.body)
        else {
            return Fail(error: HTTPError.invalidJSON)
                .eraseToAnyPublisher()
        }
        
        guard Features.useOnionRequests else {
            return HTTP
                .execute(
                    .post,
                    "\(request.endpoint.server)/\(request.endpoint.rawValue)",
                    body: payload
                )
                .map { response in (HTTP.ResponseInfo(code: -1, headers: [:]), response) }
                .eraseToAnyPublisher()
        }
        
        var urlRequest: URLRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.allHTTPHeaderFields = [ HTTPHeader.contentType: "application/json" ]
        urlRequest.httpBody = payload
        
        return dependencies.onionApi
            .sendOnionRequest(urlRequest, to: request.endpoint.server, with: request.endpoint.serverPublicKey)
            .eraseToAnyPublisher()
    }
}
