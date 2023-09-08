// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

public enum PushNotificationAPI {
    private static let keychainService: String = "PNKeyChainService"
    private static let encryptionKeyKey: String = "PNEncryptionKeyKey"
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
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<Void, Error> {
        typealias SubscribeAllPreparedRequests = (
            HTTP.PreparedRequest<PushNotificationAPI.SubscribeResponse>,
            HTTP.PreparedRequest<PushNotificationAPI.LegacyPushServerResponse>?
        )
        let hexEncodedToken: String = token.toHexString()
        let oldToken: String? = dependencies[singleton: .standardUserDefaults][.deviceToken]
        let lastUploadTime: Double = dependencies[singleton: .standardUserDefaults][.lastDeviceTokenUpload]
        let now: TimeInterval = Date().timeIntervalSince1970
        
        guard isForcedUpdate || hexEncodedToken != oldToken || now - lastUploadTime > tokenExpirationInterval else {
            SNLog("Device token hasn't changed or expired; no need to re-upload.")
            return Just(())
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
        
        return dependencies[singleton: .storage]
            .readPublisher(using: dependencies) { db -> SubscribeAllPreparedRequests in
                let currentUserPublicKey: String = getUserHexEncodedPublicKey(db, using: dependencies)
                let preparedUserRequest = try PushNotificationAPI
                    .preparedSubscribe(
                        db,
                        publicKey: currentUserPublicKey,
                        using: dependencies
                    )
                    .handleEvents(
                        receiveOutput: { _, response in
                            guard response.success == true else { return }
                            
                            dependencies[singleton: .standardUserDefaults][.deviceToken] = hexEncodedToken
                            dependencies[singleton: .standardUserDefaults][.lastDeviceTokenUpload] = now
                            dependencies[singleton: .standardUserDefaults][.isUsingFullAPNs] = true
                        }
                    )
                let preparedLegacyGroupRequest = try PushNotificationAPI
                    .preparedSubscribeToLegacyGroups(
                        forced: true,
                        token: hexEncodedToken,
                        currentUserPublicKey: currentUserPublicKey,
                        legacyGroupIds: try ClosedGroup
                            .select(.threadId)
                            .filter(!ClosedGroup.Columns.threadId.like("\(SessionId.Prefix.group.rawValue)%"))
                            .joining(
                                required: ClosedGroup.members
                                    .filter(GroupMember.Columns.profileId == currentUserPublicKey)
                            )
                            .asRequest(of: String.self)
                            .fetchSet(db),
                        using: dependencies
                    )
                
                return (
                    preparedUserRequest,
                    preparedLegacyGroupRequest
                )
            }
            .flatMap { userRequest, legacyGroupRequest -> AnyPublisher<Void, Error> in
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
                        ].compactMap { $0 }
                    )
                    .collect()
                    .map { _ in () }
                    .eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }
    
    public static func unsubscribeAll(
        token: Data,
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<Void, Error> {
        typealias UnsubscribeAllPreparedRequests = (
            HTTP.PreparedRequest<PushNotificationAPI.UnsubscribeResponse>,
            [HTTP.PreparedRequest<PushNotificationAPI.LegacyPushServerResponse>]
        )
        
        return dependencies[singleton: .storage]
            .readPublisher(using: dependencies) { db -> UnsubscribeAllPreparedRequests in
                guard let userED25519KeyPair: KeyPair = Identity.fetchUserEd25519KeyPair(db) else {
                    throw SnodeAPIError.noKeyPair
                }
                
                let currentUserPublicKey: String = getUserHexEncodedPublicKey(db, using: dependencies)
                let preparedUserRequest = try PushNotificationAPI
                    .preparedUnsubscribe(
                        db,
                        token: token,
                        publicKey: currentUserPublicKey,
                        subkey: nil,
                        ed25519KeyPair: userED25519KeyPair
                    )
                    .handleEvents(
                        receiveOutput: { _, response in
                            guard response.success == true else { return }
                            
                            dependencies[singleton: .standardUserDefaults][.deviceToken] = nil
                        }
                    )
                
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
                            currentUserPublicKey: currentUserPublicKey
                        )
                    }
                
                return (preparedUserRequest, preparedLegacyUnsubscribeRequests)
            }
            .flatMap { preparedUserRequest, preparedLegacyUnsubscribeRequests in
                // FIXME: Remove this once legacy groups are deprecated
                /// Unsubscribe from all legacy groups (including ones the user is no longer a member of, just in case)
                Publishers
                    .MergeMany(preparedLegacyUnsubscribeRequests.map { $0.send(using: dependencies) })
                    .collect()
                    .subscribe(on: DispatchQueue.global(qos: .userInitiated), using: dependencies)
                    .receive(on: DispatchQueue.global(qos: .userInitiated), using: dependencies)
                    .sinkUntilComplete()
                
                return preparedUserRequest.send(using: dependencies)
            }
            .map { _ in () }
            .eraseToAnyPublisher()
    }
    
    // MARK: - Prepared Requests
    
    public static func preparedSubscribe(
        _ db: Database,
        publicKey: String,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<SubscribeResponse> {
        guard
            dependencies[singleton: .standardUserDefaults][.isUsingFullAPNs],
            let token: String = dependencies[singleton: .standardUserDefaults][.deviceToken]
        else { throw HTTPError.invalidRequest }
        
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
                            switch SessionId.Prefix(from: publicKey) {
                                case .group: return [.default]
                                default: return [.default, .configConvoInfoVolatile]
                            }
                        }(),
                        // Note: Unfortunately we always need the message content because without the content
                        // control messages can't be distinguished from visible messages which results in the
                        // 'generic' notification being shown when receiving things like typing indicator updates
                        includeMessageData: true,
                        serviceInfo: SubscribeRequest.ServiceInfo(
                            token: token
                        ),
                        notificationsEncryptionKey: notificationsEncryptionKey,
                        authInfo: try SnodeAPI.AuthenticationInfo(db, threadId: publicKey, using: dependencies),
                        timestamp: (TimeInterval(SnodeAPI.currentOffsetTimestampMs()) / 1000)  // Seconds
                    )
                ),
                responseType: SubscribeResponse.self,
                retryCount: PushNotificationAPI.maxRetryCount
            )
            .handleEvents(
                receiveOutput: { _, response in
                    guard response.success == true else {
                        return SNLog("Couldn't subscribe for push notifications for: \(publicKey) due to error (\(response.error ?? -1)): \(response.message ?? "nil").")
                    }
                },
                receiveCompletion: { result in
                    switch result {
                        case .finished: break
                        case .failure: SNLog("Couldn't subscribe for push notifications for: \(publicKey).")
                    }
                }
            )
    }
    
    public static func preparedUnsubscribe(
        _ db: Database,
        token: Data,
        publicKey: String,
        subkey: String?,
        ed25519KeyPair: KeyPair,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<UnsubscribeResponse> {
        return try PushNotificationAPI
            .prepareRequest(
                request: Request(
                    method: .post,
                    endpoint: .unsubscribe,
                    body: UnsubscribeRequest(
                        serviceInfo: UnsubscribeRequest.ServiceInfo(
                            token: token.toHexString()
                        ),
                        authInfo: try SnodeAPI.AuthenticationInfo(db, threadId: publicKey, using: dependencies),
                        timestamp: (TimeInterval(SnodeAPI.currentOffsetTimestampMs()) / 1000)  // Seconds
                    )
                ),
                responseType: UnsubscribeResponse.self,
                retryCount: PushNotificationAPI.maxRetryCount
            )
            .handleEvents(
                receiveOutput: { _, response in
                    guard response.success == true else {
                        return SNLog("Couldn't unsubscribe for push notifications for: \(publicKey) due to error (\(response.error ?? -1)): \(response.message ?? "nil").")
                    }
                },
                receiveCompletion: { result in
                    switch result {
                        case .finished: break
                        case .failure: SNLog("Couldn't unsubscribe for push notifications for: \(publicKey).")
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
        using dependencies: Dependencies = Dependencies()
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
                retryCount: (maxRetryCount ?? PushNotificationAPI.maxRetryCount)
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
        currentUserPublicKey: String,
        legacyGroupIds: Set<String>,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<LegacyPushServerResponse>? {
        let isUsingFullAPNs = dependencies[singleton: .standardUserDefaults][.isUsingFullAPNs]
        
        // Only continue if PNs are enabled and we have a device token
        guard
            !legacyGroupIds.isEmpty,
            (forced || isUsingFullAPNs),
            let deviceToken: String = (token ?? dependencies[singleton: .standardUserDefaults][.deviceToken])
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
                    )
                ),
                responseType: LegacyPushServerResponse.self,
                retryCount: PushNotificationAPI.maxRetryCount
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
        currentUserPublicKey: String,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<LegacyPushServerResponse> {
        return try PushNotificationAPI
            .prepareRequest(
                request: Request(
                    method: .post,
                    endpoint: .legacyGroupUnsubscribe,
                    body: LegacyGroupRequest(
                        pubKey: currentUserPublicKey,
                        closedGroupPublicKey: legacyGroupId
                    )
                ),
                responseType: LegacyPushServerResponse.self,
                retryCount: PushNotificationAPI.maxRetryCount
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
        dependencies: Dependencies = Dependencies()
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
        
        guard let base64EncodedEncString: String = notificationContent.userInfo["enc_payload"] as? String else {
            return (nil, .failureNoContent)
        }
        
        guard
            let encData: Data = Data(base64Encoded: base64EncodedEncString),
            let notificationsEncryptionKey: Data = try? getOrGenerateEncryptionKey(using: dependencies),
            encData.count > dependencies[singleton: .crypto].size(.aeadXChaCha20NonceBytes)
        else { return (nil, .failure) }
        
        let nonce: Data = encData[0..<dependencies[singleton: .crypto].size(.aeadXChaCha20NonceBytes)]
        let payload: Data = encData[dependencies[singleton: .crypto].size(.aeadXChaCha20NonceBytes)...]
        
        guard
            let paddedData: [UInt8] = try? dependencies[singleton: .crypto].perform(
                .decryptAeadXChaCha20(
                    authenticatedCipherText: payload.bytes,
                    secretKey: notificationsEncryptionKey.bytes,
                    nonce: nonce.bytes
                )
            )
        else { return (nil, .failure) }
        
        let decryptedData: Data = Data(paddedData.reversed().drop(while: { $0 == 0 }).reversed())
        
        // Decode the decrypted data
        guard let notification: BencodeResponse<NotificationMetadata> = try? Bencode.decodeResponse(from: decryptedData) else {
            return (nil, .failure)
        }
        
        // If the metadata says that the message was too large then we should show the generic
        // notification (this is a valid case)
        guard !notification.info.dataTooLong else { return (nil, .successTooLong) }
        
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
    
    @discardableResult private static func getOrGenerateEncryptionKey(using dependencies: Dependencies) throws -> Data {
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
        using dependencies: Dependencies
    ) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
        guard
            let url: URL = URL(string: "\(request.endpoint.server)/\(request.endpoint.path)"),
            let payload: Data = try? JSONEncoder(using: dependencies).encode(request.body)
        else {
            return Fail(error: HTTPError.invalidJSON)
                .eraseToAnyPublisher()
        }
        
        guard Features.useOnionRequests else {
            return HTTP
                .execute(
                    .post,
                    "\(request.endpoint.server)/\(request.endpoint.path)",
                    body: payload
                )
                .map { response in (HTTP.ResponseInfo(code: -1, headers: [:]), response) }
                .eraseToAnyPublisher()
        }
        
        var urlRequest: URLRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.allHTTPHeaderFields = [ HTTPHeader.contentType: "application/json" ]
        urlRequest.httpBody = payload
        
        return dependencies[singleton: .network]
            .send(
                .onionRequest(
                    urlRequest,
                    to: request.endpoint.server,
                    with: request.endpoint.serverPublicKey
                )
            )
            .eraseToAnyPublisher()
    }
    
    // MARK: - Convenience
    
    private static func prepareRequest<T: Encodable, R: Decodable>(
        request: Request<T, Endpoint>,
        responseType: R.Type,
        retryCount: Int = 0,
        timeout: TimeInterval = HTTP.defaultTimeout,
        using dependencies: Dependencies = Dependencies()
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
