// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

// MARK: - KeychainStorage

public extension KeychainStorage.ServiceKey { static let pushNotificationAPI: Self = "PNKeyChainService" }
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
        
    // MARK: - Batch Requests
    
    public static func subscribeAll(
        token: Data,
        isForcedUpdate: Bool,
        using dependencies: Dependencies
    ) -> AnyPublisher<Void, Error> {
        typealias SubscribeAllPreparedRequests = (
            HTTP.PreparedRequest<PushNotificationAPI.SubscribeResponse>,
            [HTTP.PreparedRequest<PushNotificationAPI.SubscribeResponse>],
            HTTP.PreparedRequest<PushNotificationAPI.LegacyPushServerResponse>?
        )
        let hexEncodedToken: String = token.toHexString()
        let oldToken: String? = dependencies[defaults: .standard, key: .deviceToken]
        let lastUploadTime: Double = dependencies[defaults: .standard, key: .lastDeviceTokenUpload]
        let now: TimeInterval = dependencies.dateNow.timeIntervalSince1970
        
        guard isForcedUpdate || hexEncodedToken != oldToken || now - lastUploadTime > tokenExpirationInterval else {
            SNLog("Device token hasn't changed or expired; no need to re-upload.")
            return Just(())
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
        
        return dependencies[singleton: .storage]
            .readPublisher(using: dependencies) { db -> SubscribeAllPreparedRequests in
                let userSessionId: SessionId = getUserSessionId(db, using: dependencies)
                let preparedUserRequest = try PushNotificationAPI
                    .preparedSubscribe(
                        db,
                        token: token,
                        sessionId: userSessionId,
                        using: dependencies
                    )
                    .handleEvents(
                        receiveOutput: { _, response in
                            guard response.success == true else { return }
                            
                            dependencies[defaults: .standard, key: .deviceToken] = hexEncodedToken
                            dependencies[defaults: .standard, key: .lastDeviceTokenUpload] = now
                            dependencies[defaults: .standard, key: .isUsingFullAPNs] = true
                        }
                    )
                let preparedGroupRequests = try ClosedGroup
                    .select(.threadId)
                    .filter(ClosedGroup.Columns.threadId.like("\(SessionId.Prefix.group.rawValue)%"))
                    .filter(ClosedGroup.Columns.shouldPoll)
                    .asRequest(of: String.self)
                    .fetchSet(db)
                    .map { groupId in
                        try PushNotificationAPI
                            .preparedSubscribe(
                                db,
                                token: token,
                                sessionId: SessionId(.group, hex: groupId),
                                using: dependencies
                            )
                    }
                let preparedLegacyGroupRequest = try PushNotificationAPI
                    .preparedSubscribeToLegacyGroups(
                        forced: true,
                        token: hexEncodedToken,
                        userSessionId: userSessionId,
                        legacyGroupIds: try ClosedGroup
                            .select(.threadId)
                            .filter(!ClosedGroup.Columns.threadId.like("\(SessionId.Prefix.group.rawValue)%"))
                            .joining(
                                required: ClosedGroup.members
                                    .filter(GroupMember.Columns.profileId == userSessionId.hexString)
                            )
                            .asRequest(of: String.self)
                            .fetchSet(db),
                        using: dependencies
                    )
                
                return (
                    preparedUserRequest,
                    preparedGroupRequests,
                    preparedLegacyGroupRequest
                )
            }
            .flatMap { userRequest, preparedGroupRequests, legacyGroupRequest -> AnyPublisher<Void, Error> in
                Publishers
                    .MergeMany(
                        [
                            userRequest
                                .send(using: dependencies)
                                .map { _, _ in () }
                                .eraseToAnyPublisher(),
                            // FIXME: Remove this once legacy groups are deprecated
                            legacyGroupRequest?
                                .send(using: dependencies)
                                .map { _, _ in () }
                                .eraseToAnyPublisher()
                        ]
                        .appending(
                            contentsOf: preparedGroupRequests.map { request in
                                request
                                    .send(using: dependencies)
                                    .map { _, _ in () }
                                    .eraseToAnyPublisher()
                            }
                        )
                        .compactMap { $0 }
                    )
                    .collect()
                    .map { _ in () }
                    .eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }
    
    public static func unsubscribeAll(
        token: Data,
        using dependencies: Dependencies
    ) -> AnyPublisher<Void, Error> {
        typealias UnsubscribeAllPreparedRequests = (
            HTTP.PreparedRequest<PushNotificationAPI.UnsubscribeResponse>,
            [HTTP.PreparedRequest<PushNotificationAPI.UnsubscribeResponse>],
            [HTTP.PreparedRequest<PushNotificationAPI.LegacyPushServerResponse>]
        )
        
        return dependencies[singleton: .storage]
            .readPublisher(using: dependencies) { db -> UnsubscribeAllPreparedRequests in
                let userSessionId: SessionId = getUserSessionId(db, using: dependencies)
                let preparedUserRequest = try PushNotificationAPI
                    .preparedUnsubscribe(
                        db,
                        token: token,
                        sessionId: userSessionId,
                        using: dependencies
                    )
                    .handleEvents(
                        receiveOutput: { _, response in
                            guard response.success == true else { return }
                            
                            dependencies[defaults: .standard, key: .deviceToken] = nil
                        }
                    )
                let preparedGroupUnsubscribeRequests = (try? ClosedGroup
                    .select(.threadId)
                    .filter(ClosedGroup.Columns.threadId.like("\(SessionId.Prefix.group.rawValue)%"))
                    .asRequest(of: String.self)
                    .fetchSet(db))
                    .defaulting(to: [])
                    .compactMap { groupId in
                        try? PushNotificationAPI.preparedUnsubscribe(
                            db,
                            token: token,
                            sessionId: SessionId(.group, hex: groupId),
                            using: dependencies
                        )
                    }
                
                // FIXME: Remove this once legacy groups are deprecated
                let preparedLegacyUnsubscribeRequests = (try? ClosedGroup
                    .select(.threadId)
                    .filter(!ClosedGroup.Columns.threadId.like("\(SessionId.Prefix.group.rawValue)%"))
                    .asRequest(of: String.self)
                    .fetchSet(db))
                    .defaulting(to: [])
                    .compactMap { legacyGroupId in
                        try? PushNotificationAPI.preparedUnsubscribeFromLegacyGroup(
                            legacyGroupId: legacyGroupId,
                            userSessionId: userSessionId,
                            using: dependencies
                        )
                    }
                
                return (preparedUserRequest, preparedGroupUnsubscribeRequests, preparedLegacyUnsubscribeRequests)
            }
            .flatMap { preparedUserRequest, preparedGroupUnsubscribeRequests, preparedLegacyUnsubscribeRequests in
                // FIXME: Remove this once legacy groups are deprecated
                /// Unsubscribe from all legacy groups (including ones the user is no longer a member of, just in case)
                Publishers
                    .MergeMany(preparedLegacyUnsubscribeRequests.map { $0.send(using: dependencies) })
                    .collect()
                    .subscribe(on: DispatchQueue.global(qos: .userInitiated), using: dependencies)
                    .receive(on: DispatchQueue.global(qos: .userInitiated), using: dependencies)
                    .sinkUntilComplete()
                
                return Publishers
                    .MergeMany(
                        [
                            preparedUserRequest
                                .send(using: dependencies)
                                .map { _, _ in () }
                                .eraseToAnyPublisher()
                        ]
                        .appending(
                            contentsOf: preparedGroupUnsubscribeRequests.map { request in
                                request
                                    .send(using: dependencies)
                                    .map { _, _ in () }
                                    .eraseToAnyPublisher()
                            }
                        )
                    )
            }
            .eraseToAnyPublisher()
    }
    
    // MARK: - Prepared Requests
    
    public static func preparedSubscribe(
        _ db: Database,
        token: Data,
        sessionId: SessionId,
        using dependencies: Dependencies
    ) throws -> HTTP.PreparedRequest<SubscribeResponse> {
        guard dependencies[defaults: .standard, key: .isUsingFullAPNs] else { throw HTTPError.invalidRequest }
        
        guard let notificationsEncryptionKey: Data = try? getOrGenerateEncryptionKey(using: dependencies) else {
            SNLog("Unable to retrieve PN encryption key.")
            throw StorageError.invalidKeySpec
        }
        
        return try PushNotificationAPI
            .prepareRequest(
                request: Request(
                    method: .post,
                    endpoint: .subscribe,
                    body: SubscribeRequest(
                        namespaces: {
                            switch sessionId.prefix {
                                case .group: return [.groupMessages]
                                default: return [.default, .configConvoInfoVolatile]
                            }
                        }(),
                        // Note: Unfortunately we always need the message content because without the content
                        // control messages can't be distinguished from visible messages which results in the
                        // 'generic' notification being shown when receiving things like typing indicator updates
                        includeMessageData: true,
                        serviceInfo: ServiceInfo(
                            token: token.toHexString()
                        ),
                        notificationsEncryptionKey: notificationsEncryptionKey,
                        authMethod: try Authentication.with(
                            db,
                            sessionIdHexString: sessionId.hexString,
                            using: dependencies
                        ),
                        timestamp: TimeInterval(
                            (Double(SnodeAPI.currentOffsetTimestampMs(using: dependencies)) / 1000) // Seconds
                        )
                    )
                ),
                responseType: SubscribeResponse.self,
                retryCount: PushNotificationAPI.maxRetryCount,
                using: dependencies
            )
            .handleEvents(
                receiveOutput: { _, response in
                    guard response.success == true else {
                        return SNLog("Couldn't subscribe for push notifications for: \(sessionId) due to error (\(response.error ?? -1)): \(response.message ?? "nil").")
                    }
                },
                receiveCompletion: { result in
                    switch result {
                        case .finished: break
                        case .failure: SNLog("Couldn't subscribe for push notifications for: \(sessionId).")
                    }
                }
            )
    }
    
    public static func preparedUnsubscribe(
        _ db: Database,
        token: Data,
        sessionId: SessionId,
        using dependencies: Dependencies
    ) throws -> HTTP.PreparedRequest<UnsubscribeResponse> {
        return try PushNotificationAPI
            .prepareRequest(
                request: Request(
                    method: .post,
                    endpoint: .unsubscribe,
                    body: UnsubscribeRequest(
                        serviceInfo: ServiceInfo(
                            token: token.toHexString()
                        ),
                        authMethod: try Authentication.with(
                            db,
                            sessionIdHexString: sessionId.hexString,
                            using: dependencies
                        ),
                        timestamp: TimeInterval(
                            (Double(SnodeAPI.currentOffsetTimestampMs(using: dependencies)) / 1000) // Seconds
                        )
                    )
                ),
                responseType: UnsubscribeResponse.self,
                retryCount: PushNotificationAPI.maxRetryCount,
                using: dependencies
            )
            .handleEvents(
                receiveOutput: { _, response in
                    guard response.success == true else {
                        return SNLog("Couldn't unsubscribe for push notifications for: \(sessionId) due to error (\(response.error ?? -1)): \(response.message ?? "nil").")
                    }
                },
                receiveCompletion: { result in
                    switch result {
                        case .finished: break
                        case .failure: SNLog("Couldn't unsubscribe for push notifications for: \(sessionId).")
                    }
                }
            )
    }
    
    // MARK: - Legacy Notifications
    
    // FIXME: Remove this once legacy notifications and legacy groups are deprecated
    public static func preparedLegacyNotify(
        recipient: String,
        with message: String,
        maxRetryCount: Int? = nil,
        using dependencies: Dependencies
    ) throws -> HTTP.PreparedRequest<LegacyPushServerResponse> {
        return try PushNotificationAPI
            .prepareRequest(
                request: Request(
                    method: .post,
                    endpoint: .legacyNotify,
                    body: LegacyNotifyRequest(
                        data: message,
                        sendTo: recipient
                    )
                ),
                responseType: LegacyPushServerResponse.self,
                retryCount: (maxRetryCount ?? PushNotificationAPI.maxRetryCount),
                using: dependencies
            )
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
    }
    
    // MARK: - Legacy Groups
    
    // FIXME: Remove this once legacy groups are deprecated
    public static func preparedSubscribeToLegacyGroups(
        forced: Bool = false,
        token: String? = nil,
        userSessionId: SessionId,
        legacyGroupIds: Set<String>,
        using dependencies: Dependencies
    ) throws -> HTTP.PreparedRequest<LegacyPushServerResponse>? {
        let isUsingFullAPNs = dependencies[defaults: .standard, key: .isUsingFullAPNs]
        
        // Only continue if PNs are enabled and we have a device token
        guard
            !legacyGroupIds.isEmpty,
            (forced || isUsingFullAPNs),
            let deviceToken: String = (token ?? dependencies[defaults: .standard, key: .deviceToken])
        else { return nil }
        
        return try PushNotificationAPI
            .prepareRequest(
                request: Request(
                    method: .post,
                    endpoint: .legacyGroupsOnlySubscribe,
                    body: LegacyGroupOnlyRequest(
                        token: deviceToken,
                        pubKey: userSessionId.hexString,
                        device: "ios",
                        legacyGroupPublicKeys: legacyGroupIds
                    )
                ),
                responseType: LegacyPushServerResponse.self,
                retryCount: PushNotificationAPI.maxRetryCount,
                using: dependencies
            )
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
    }
    
    // FIXME: Remove this once legacy groups are deprecated
    public static func preparedUnsubscribeFromLegacyGroup(
        legacyGroupId: String,
        userSessionId: SessionId,
        using dependencies: Dependencies
    ) throws -> HTTP.PreparedRequest<LegacyPushServerResponse> {
        return try PushNotificationAPI
            .prepareRequest(
                request: Request(
                    method: .post,
                    endpoint: .legacyGroupUnsubscribe,
                    body: LegacyGroupRequest(
                        pubKey: userSessionId.hexString,
                        closedGroupPublicKey: legacyGroupId
                    )
                ),
                responseType: LegacyPushServerResponse.self,
                retryCount: PushNotificationAPI.maxRetryCount,
                using: dependencies
            )
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
                envelope.type == .closedGroupMessage
            else { return (data, .invalid, .legacyForceSilent) }

            return (data, .invalid, .legacySuccess)
        }
        
        guard let base64EncodedEncString: String = notificationContent.userInfo["enc_payload"] as? String else {
            return (nil, .invalid, .failureNoContent)
        }
        
        guard
            let encData: Data = Data(base64Encoded: base64EncodedEncString),
            let notificationsEncryptionKey: Data = try? getOrGenerateEncryptionKey(using: dependencies),
            encData.count > dependencies[singleton: .crypto].size(.aeadXChaCha20NonceBytes)
        else { return (nil, .invalid, .failure) }
        
        let nonce: Data = encData[0..<dependencies[singleton: .crypto].size(.aeadXChaCha20NonceBytes)]
        let payload: Data = encData[dependencies[singleton: .crypto].size(.aeadXChaCha20NonceBytes)...]
        
        guard
            let paddedData: [UInt8] = dependencies[singleton: .crypto].generate(
                .decryptedBytesAeadXChaCha20(
                    authenticatedCipherText: payload.bytes,
                    secretKey: notificationsEncryptionKey.bytes,
                    nonce: nonce.bytes
                )
            )
        else { return (nil, .invalid, .failure) }
        
        let decryptedData: Data = Data(paddedData.reversed().drop(while: { $0 == 0 }).reversed())
        
        // Decode the decrypted data
        guard let notification: BencodeResponse<NotificationMetadata> = try? Bencode.decodeResponse(from: decryptedData) else {
            return (nil, .invalid, .failure)
        }
        
        // If the metadata says that the message was too large then we should show the generic
        // notification (this is a valid case)
        guard !notification.info.dataTooLong else { return (nil, notification.info, .successTooLong) }
        
        // Check that the body we were given is valid
        guard
            let notificationData: Data = notification.data,
            notification.info.dataLength == notificationData.count
        else { return (nil, notification.info, .failure) }
        
        // Success, we have the notification content
        return (notificationData, notification.info, .success)
    }
                        
    // MARK: - Security
    
    @discardableResult private static func getOrGenerateEncryptionKey(using dependencies: Dependencies) throws -> Data {
        do {
            var encryptionKey: Data = try dependencies[singleton: .keychain].data(
                forService: .pushNotificationAPI,
                key: .pushNotificationEncryptionKey
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
                        var keySpec: Data = try Data(dependencies[singleton: .crypto]
                            .tryGenerate(.randomBytes(numberBytes: encryptionKeyLength)))
                        defer { keySpec.resetBytes(in: 0..<keySpec.count) } // Reset content immediately after use
                        
                        try dependencies[singleton: .keychain].set(
                            data: keySpec,
                            service: .pushNotificationAPI,
                            key: .pushNotificationEncryptionKey
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
    
    public static func deleteKeys(using dependencies: Dependencies = Dependencies()) {
        try? dependencies[singleton: .keychain].remove(service: .pushNotificationAPI, key: .pushNotificationEncryptionKey)
    }
    
    // MARK: - Convenience
    
    private static func prepareRequest<T: Encodable, R: Decodable>(
        request: Request<T, Endpoint>,
        responseType: R.Type,
        retryCount: Int = 0,
        timeout: TimeInterval = HTTP.defaultTimeout,
        using dependencies: Dependencies
    ) throws -> HTTP.PreparedRequest<R> {
        return HTTP.PreparedRequest<R>(
            request: request,
            urlRequest: try request.generateUrlRequest(using: dependencies),
            responseType: responseType,
            retryCount: retryCount,
            timeout: timeout
        )
    }
}
