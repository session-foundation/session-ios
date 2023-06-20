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
                let request: SubscribeRequest = SubscribeRequest(
                    pubkey: currentUserPublicKey,
                    namespaces: [.default],
                    // Note: Unfortunately we always need the message content because without the content
                    // control messages can't be distinguished from visible messages which results in the
                    // 'generic' notification being shown when receiving things like typing indicator updates
                    includeMessageData: true,
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
                                .map { _ in () }
                                .eraseToAnyPublisher(),
                            // FIXME: Remove this once legacy groups are deprecated
                            PushNotificationAPI
                                .send(
                                    request: PushNotificationAPIRequest(
                                        endpoint: .legacyGroupsOnlySubscribe,
                                        body: LegacyGroupOnlyRequest(
                                            token: hexEncodedToken,
                                            pubKey: currentUserPublicKey,
                                            device: "ios",
                                            legacyGroupPublicKeys: legacyGroupIds
                                        )
                                    )
                                )
                                .decoded(as: LegacyPushServerResponse.self, using: dependencies)
                                .retry(maxRetryCount)
                                .handleEvents(
                                    receiveOutput: { _, response in
                                        guard response.code != 0 else {
                                            return SNLog("Couldn't subscribe for legacy groups due to error: \(response.message ?? "nil").")
                                        }
                                    },
                                    receiveCompletion: { result in
                                        switch result {
                                            case .finished: break
                                            case .failure: SNLog("Couldn't subscribe for legacy groups.")
                                        }
                                    }
                                )
                                .map { _ in () }
                                .eraseToAnyPublisher()
                        ]
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
    
    // MARK: - Notification Handling
    
    public static func processNotification(
        notificationContent: UNNotificationContent,
        dependencies: SMKDependencies = SMKDependencies()
    ) -> (envelope: SNProtoEnvelope?, result: ProcessResult) {
        // Make sure the notification is from the updated push server
        guard notificationContent.userInfo["spns"] != nil else {
            guard
                let base64EncodedData: String = notificationContent.userInfo["ENCRYPTED_DATA"] as? String,
                let data: Data = Data(base64Encoded: base64EncodedData),
                let envelope: SNProtoEnvelope = try? MessageWrapper.unwrap(data: data)
            else { return (nil, .legacyFailure) }
            
            // We only support legacy notifications for legacy group conversations
            guard envelope.type == .closedGroupMessage else { return (envelope, .legacyForceSilent) }

            return (envelope, .legacySuccess)
        }
        
        guard
            let base64EncodedEncString: String = notificationContent.userInfo["enc_payload"] as? String,
            let encData: Data = Data(base64Encoded: base64EncodedEncString),
            let notificationsEncryptionKey: Data = try? getOrGenerateEncryptionKey(),
            encData.count > dependencies.aeadXChaCha20Poly1305Ietf.NonceBytes
        else { return (nil, .failure) }
        
        let nonce: Data = encData[0..<dependencies.aeadXChaCha20Poly1305Ietf.NonceBytes]
        let payload: Data = encData[dependencies.aeadXChaCha20Poly1305Ietf.NonceBytes...]
        
        guard
            let paddedData: [UInt8] = dependencies.aeadXChaCha20Poly1305Ietf.decrypt(
                authenticatedCipherText: payload.bytes,
                secretKey: notificationsEncryptionKey.bytes,
                nonce: nonce.bytes
            )
        else { return (nil, .failure) }
        
        let decryptedData: Data = Data(paddedData.reversed().drop(while: { $0 == 0 }).reversed())
        
        // Decode the decrypted data
        guard let notification: BencodeResponse<NotificationMetadata> = try? Bencode.decodeResponse(from: decryptedData) else {
            return (nil, .failure)
        }
        
        // If the metadata says that the message was too large then we should show the generic
        // notification (this is a valid case)
        guard !notification.info.dataTooLong else { return (nil, .success) }
        
        // Check that the body we were given is valid
        guard
            let notificationData: Data = notification.data,
            notification.info.dataLength == notificationData.count,
            let envelope = try? MessageWrapper.unwrap(data: notificationData)
        else { return (nil, .failure) }
        
        // Success, we have the notification content
        return (envelope, .success)
    }
                        
    // MARK: - Security
    
    @discardableResult private static func getOrGenerateEncryptionKey() throws -> Data {
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
