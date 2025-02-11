// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

// MARK: - KeychainStorage

public extension KeychainStorage.DataKey { static let pushNotificationEncryptionKey: Self = "PNEncryptionKeyKey" }

// MARK: - PushNotificationAPI

public enum PushNotificationAPI {
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
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<Void, Error> {
        typealias SubscribeAllPreparedRequests = (
            SubscribeRequest,
            String,
            Network.PreparedRequest<PushNotificationAPI.LegacyPushServerResponse>?
        )
        let hexEncodedToken: String = token.toHexString()
        let oldToken: String? = dependencies.standardUserDefaults[.deviceToken]
        let lastUploadTime: Double = dependencies.standardUserDefaults[.lastDeviceTokenUpload]
        let now: TimeInterval = Date().timeIntervalSince1970
        
        guard isForcedUpdate || hexEncodedToken != oldToken || now - lastUploadTime > tokenExpirationInterval else {
            SNLog("Device token hasn't changed or expired; no need to re-upload.")
            return Just(())
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
        
        guard let notificationsEncryptionKey: Data = try? getOrGenerateEncryptionKey(using: dependencies) else {
            SNLog("Unable to retrieve PN encryption key.")
            return Just(())
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
        
        // TODO: Need to generate requests for each updated group as well
        return dependencies.storage
            .readPublisher(using: dependencies) { db -> SubscribeAllPreparedRequests in
                guard let userED25519KeyPair: KeyPair = Identity.fetchUserEd25519KeyPair(db) else {
                    throw SnodeAPIError.noKeyPair
                }
                
                let currentUserPublicKey: String = getUserHexEncodedPublicKey(db, using: dependencies)
                let request: SubscribeRequest = SubscribeRequest(
                    pubkey: currentUserPublicKey,
                    namespaces: [.default, .configConvoInfoVolatile],
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
                let preparedLegacyGroupRequest = try PushNotificationAPI
                    .preparedSubscribeToLegacyGroups(
                        forced: true,
                        token: hexEncodedToken,
                        currentUserPublicKey: currentUserPublicKey,
                        legacyGroupIds: try ClosedGroup
                            .select(.threadId)
                            .filter(
                                ClosedGroup.Columns.threadId > SessionId.Prefix.standard.rawValue &&
                                ClosedGroup.Columns.threadId < SessionId.Prefix.standard.endOfRangeString
                            )
                            .joining(
                                required: ClosedGroup.members
                                    .filter(GroupMember.Columns.profileId == currentUserPublicKey)
                            )
                            .asRequest(of: String.self)
                            .fetchSet(db),
                        using: dependencies
                    )
                
                return (
                    request,
                    currentUserPublicKey,
                    preparedLegacyGroupRequest
                )
            }
            .tryFlatMap { request, currentUserPublicKey, legacyGroupRequest -> AnyPublisher<Void, Error> in
                Publishers
                    .MergeMany(
                        [
                            try PushNotificationAPI
                                .prepareRequest(
                                    request: Request(
                                        method: .post,
                                        endpoint: .subscribe,
                                        body: request,
                                        using: dependencies
                                    ),
                                    responseType: SubscribeResponse.self,
                                    using: dependencies
                                )
                                .send(using: dependencies)
                                .retry(maxRetryCount, using: dependencies)
                                .handleEvents(
                                    receiveOutput: { _, response in
                                        guard response.success == true else {
                                            return SNLog("Couldn't subscribe for push notifications due to error (\(response.error ?? -1)): \(response.message ?? "nil").")
                                        }
                                        
                                        dependencies.standardUserDefaults[.deviceToken] = hexEncodedToken
                                        dependencies.standardUserDefaults[.lastDeviceTokenUpload] = now
                                        dependencies.standardUserDefaults[.isUsingFullAPNs] = true
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
                            legacyGroupRequest?
                                .send(using: dependencies)
                                .map { _, _ in () }
                                .eraseToAnyPublisher()
                        ]
                        .compactMap { $0 }
                    )
                    .collect()
                    .map { _ in () }
                    .eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }
    
    public static func unsubscribe(
        token: Data,
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<Void, Error> {
        let hexEncodedToken: String = token.toHexString()
        
        // FIXME: Remove this once legacy groups are deprecated
        /// Unsubscribe from all legacy groups (including ones the user is no longer a member of, just in case)
        dependencies.storage
            .readPublisher(using: dependencies) { db -> (String, Set<String>) in
                (
                    getUserHexEncodedPublicKey(db, using: dependencies),
                    try ClosedGroup
                        .select(.threadId)
                        .filter(
                            ClosedGroup.Columns.threadId > SessionId.Prefix.standard.rawValue &&
                            ClosedGroup.Columns.threadId < SessionId.Prefix.standard.endOfRangeString
                        )
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
            .subscribe(on: DispatchQueue.global(qos: .userInitiated), using: dependencies)
            .sinkUntilComplete()
        
        // TODO: Need to generate requests for each updated group as well
        return dependencies.storage
            .readPublisher(using: dependencies) { db -> UnsubscribeRequest in
                guard let userED25519KeyPair: KeyPair = Identity.fetchUserEd25519KeyPair(db) else {
                    throw SnodeAPIError.noKeyPair
                }
                
                return UnsubscribeRequest(
                    pubkey: getUserHexEncodedPublicKey(db, using: dependencies),
                    serviceInfo: UnsubscribeRequest.ServiceInfo(
                        token: hexEncodedToken
                    ),
                    subkey: nil,
                    timestamp: (TimeInterval(SnodeAPI.currentOffsetTimestampMs()) / 1000),  // Seconds
                    ed25519PublicKey: userED25519KeyPair.publicKey,
                    ed25519SecretKey: userED25519KeyPair.secretKey
                )
            }
            .tryFlatMap { request -> AnyPublisher<Void, Error> in
                try PushNotificationAPI
                    .prepareRequest(
                        request: Request(
                            method: .post,
                            endpoint: .unsubscribe,
                            body: request,
                            using: dependencies
                        ),
                        responseType: UnsubscribeResponse.self,
                        using: dependencies
                    )
                    .send(using: dependencies)
                    .retry(maxRetryCount, using: dependencies)
                    .handleEvents(
                        receiveOutput: { _, response in
                            guard response.success == true else {
                                return SNLog("Couldn't unsubscribe for push notifications due to error (\(response.error ?? -1)): \(response.message ?? "nil").")
                            }
                            
                            dependencies.standardUserDefaults[.deviceToken] = nil
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
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<Void, Error> {
        do {
            return try PushNotificationAPI
                .prepareRequest(
                    request: Request(
                        method: .post,
                        endpoint: .legacyNotify,
                        body: LegacyNotifyRequest(
                            data: message,
                            sendTo: recipient
                        ),
                        using: dependencies
                    ),
                    responseType: LegacyPushServerResponse.self,
                    using: dependencies
                )
                .send(using: dependencies)
                .retry(maxRetryCount ?? PushNotificationAPI.maxRetryCount, using: dependencies)
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
        catch { return Fail(error: error).eraseToAnyPublisher() }
    }
    
    // MARK: - Legacy Groups
    
    // FIXME: Remove this once legacy groups are deprecated
    public static func preparedSubscribeToLegacyGroups(
        forced: Bool = false,
        token: String? = nil,
        currentUserPublicKey: String,
        legacyGroupIds: Set<String>,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<LegacyPushServerResponse>? {
        let isUsingFullAPNs = dependencies.standardUserDefaults[.isUsingFullAPNs]
        
        // Only continue if PNs are enabled and we have a device token
        guard
            !legacyGroupIds.isEmpty,
            (forced || isUsingFullAPNs),
            let deviceToken: String = (token ?? dependencies.standardUserDefaults[.deviceToken])
        else { return nil }
        
        return try PushNotificationAPI
            .prepareRequest(
                request: Request(
                    method: .post,
                    endpoint: .legacyGroupsOnlySubscribe,
                    body: LegacyGroupOnlyRequest(
                        token: deviceToken,
                        pubKey: currentUserPublicKey,
                        device: "ios",
                        legacyGroupPublicKeys: legacyGroupIds
                    ),
                    using: dependencies
                ),
                responseType: LegacyPushServerResponse.self,
                retryCount: PushNotificationAPI.maxRetryCount,
                using: dependencies
            )
            .handleEvents(
                receiveOutput: { _, response in
                    guard response.code != 0 else {
                        return Log.error("[PushNotificationAPI] Couldn't subscribe for legacy groups due to error: \(response.message ?? "nil").")
                    }
                },
                receiveCompletion: { result in
                    switch result {
                        case .finished: break
                        case .failure(let error):
                            Log.error("[PushNotificationAPI] Couldn't subscribe for legacy groups due to error: \(error).")
                    }
                }
            )
    }
    
    // FIXME: Remove this once legacy groups are deprecated
    public static func unsubscribeFromLegacyGroup(
        legacyGroupId: String,
        currentUserPublicKey: String,
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<Void, Error> {
        do {
            return try PushNotificationAPI
                .prepareRequest(
                    request: Request(
                        method: .post,
                        endpoint: .legacyGroupUnsubscribe,
                        body: LegacyGroupRequest(
                            pubKey: currentUserPublicKey,
                            closedGroupPublicKey: legacyGroupId
                        ),
                        using: dependencies
                    ),
                    responseType: LegacyPushServerResponse.self,
                    using: dependencies
                )
                .send(using: dependencies)
                .retry(maxRetryCount, using: dependencies)
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
        catch { return Fail(error: error).eraseToAnyPublisher() }
    }
    
    // MARK: - Notification Handling
    
    public static func processNotification(
        notificationContent: UNNotificationContent,
        using dependencies: Dependencies
    ) -> (data: Data?, metadata: NotificationMetadata, result: ProcessResult) {
        // Make sure the notification is from the updated push server
        guard notificationContent.userInfo["spns"] != nil else {
            guard
                let base64EncodedData: String = notificationContent.userInfo["ENCRYPTED_DATA"] as? String,
                let data: Data = Data(base64Encoded: base64EncodedData)
            else { return (nil, .invalid, .legacyFailure) }
            
            // We only support legacy notifications for legacy group conversations
            guard
                let envelope: SNProtoEnvelope = try? MessageWrapper.unwrap(data: data),
                envelope.type == .closedGroupMessage,
                let metadata: NotificationMetadata = try? .legacyGroupMessage(envelope: envelope)
            else { return (data, .invalid, .legacyForceSilent) }

            return (data, metadata, .legacySuccess)
        }
        
        guard let base64EncodedEncString: String = notificationContent.userInfo["enc_payload"] as? String else {
            return (nil, .invalid, .failureNoContent)
        }
        
        // Decrypt and decode the payload
        guard
            let encryptedData: Data = Data(base64Encoded: base64EncodedEncString),
            let notificationsEncryptionKey: Data = try? getOrGenerateEncryptionKey(using: dependencies),
            let decryptedData: Data = dependencies.crypto.generate(
                .plaintextWithPushNotificationPayload(
                    payload: encryptedData,
                    encKey: notificationsEncryptionKey
                )
            ),
            let notification: BencodeResponse<NotificationMetadata> = try? BencodeDecoder(using: dependencies)
                .decode(BencodeResponse<NotificationMetadata>.self, from: decryptedData)
        else {
            SNLog("Failed to decrypt or decode notification")
            return (nil, .invalid, .failure)
        }
        
        // If the metadata says that the message was too large then we should show the generic
        // notification (this is a valid case)
        guard !notification.info.dataTooLong else {
            SNLog("Ignoring notification due to data being too long")
            return (nil, notification.info, .successTooLong)
        }
        
        // Check that the body we were given is valid and not empty
        guard
            let notificationData: Data = notification.data,
            notification.info.dataLength == notificationData.count,
            !notificationData.isEmpty
        else {
            SNLog("Get notification data failed")
            return (nil, notification.info, .failureNoContent)
        }
        
        // Success, we have the notification content
        return (notificationData, notification.info, .success)
    }
                        
    // MARK: - Security
    
    @discardableResult private static func getOrGenerateEncryptionKey(using dependencies: Dependencies) throws -> Data {
        do {
            try Singleton.keychain.migrateLegacyKeyIfNeeded(
                legacyKey: "PNEncryptionKeyKey",
                legacyService: "PNKeyChainService",
                toKey: .pushNotificationEncryptionKey
            )
            var encryptionKey: Data = try Singleton.keychain.data(forKey: .pushNotificationEncryptionKey)
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
                        
                        try Singleton.keychain.set(data: keySpec, forKey: .pushNotificationEncryptionKey)
                        return keySpec
                    }
                    catch {
                        SNLog("Setting keychain value failed with error: \(error)")
                        throw StorageError.keySpecCreationFailed
                    }
                    
                default:
                    // Because we use kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, the keychain will be inaccessible
                    // after device restart until device is unlocked for the first time. If the app receives a push
                    // notification, we won't be able to access the keychain to process that notification, so we should
                    // just terminate by throwing an uncaught exception
                    if Singleton.hasAppContext && (Singleton.appContext.isMainApp || Singleton.appContext.isInBackground) {
                        let appState: UIApplication.State = Singleton.appContext.reportedApplicationState
                        SNLog("CipherKeySpec inaccessible. New install or no unlock since device restart?, ApplicationState: \(appState.name)")
                        throw StorageError.keySpecInaccessible
                    }
                    
                    SNLog("CipherKeySpec inaccessible; not main app.")
                    throw StorageError.keySpecInaccessible
            }
        }
    }
    
    public static func resetKeys() {
        try? Singleton.keychain.remove(key: .pushNotificationEncryptionKey)
    }
    
    // MARK: - Convenience
    
    private static func prepareRequest<T: Encodable, R: Decodable>(
        request: Request<T, Endpoint>,
        responseType: R.Type,
        retryCount: Int = 0,
        requestTimeout: TimeInterval = Network.defaultTimeout,
        requestAndPathBuildTimeout: TimeInterval? = nil,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<R> {
        return Network.PreparedRequest<R>(
            request: request,
            urlRequest: try request.generateUrlRequest(using: dependencies),
            responseType: responseType,
            retryCount: retryCount,
            requestTimeout: requestTimeout,
            requestAndPathBuildTimeout: requestAndPathBuildTimeout
        )
    }
}
