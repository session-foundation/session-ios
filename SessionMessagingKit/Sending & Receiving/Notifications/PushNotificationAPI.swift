// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import GRDB
import SessionNetworkingKit
import SessionUtilitiesKit

// MARK: - KeychainStorage

public extension KeychainStorage.DataKey { static let pushNotificationEncryptionKey: Self = "PNEncryptionKeyKey" }

// MARK: - Log.Category

private extension Log.Category {
    static let cat: Log.Category = .create("PushNotificationAPI", defaultLevel: .info)
}

// MARK: - PushNotificationAPI

public enum PushNotificationAPI {
    internal static let encryptionKeyLength: Int = 32
    private static let maxRetryCount: Int = 4
    private static let tokenExpirationInterval: TimeInterval = (12 * 60 * 60)
    
    public static let server: String = "https://push.getsession.org"
    public static let serverPublicKey = "d7557fe563e2610de876c0ac7341b62f3c82d5eea4b62c702392ea4368f51b3b"
        
    // MARK: - Batch Requests
    
    public static func subscribeAll(
        token: Data,
        isForcedUpdate: Bool,
        using dependencies: Dependencies
    ) async throws {
        let hexEncodedToken: String = token.toHexString()
        let oldToken: String? = dependencies[defaults: .standard, key: .deviceToken]
        let lastUploadTime: Double = dependencies[defaults: .standard, key: .lastDeviceTokenUpload]
        let now: TimeInterval = dependencies.dateNow.timeIntervalSince1970
        
        guard isForcedUpdate || hexEncodedToken != oldToken || now - lastUploadTime > tokenExpirationInterval else {
            return Log.info(.cat, "Device token hasn't changed or expired; no need to re-upload.")
        }
        
        let swarmAuthentication: [AuthenticationMethod] = try await retrieveAllSwarmAuth(using: dependencies)
        let response: SubscribeResponse = try await PushNotificationAPI.subscribe(
            token: token,
            swarmAuthentication: swarmAuthentication,
            using: dependencies
        )
        
        /// Only cache the token data If we successfully subscribed for user PNs
        if response.subResponses.first?.success == true {
            dependencies[defaults: .standard, key: .deviceToken] = hexEncodedToken
            dependencies[defaults: .standard, key: .lastDeviceTokenUpload] = now
            dependencies[defaults: .standard, key: .isUsingFullAPNs] = true
        }
    }
    
    public static func unsubscribeAll(
        token: Data,
        using dependencies: Dependencies
    ) async throws {
        let swarmAuthentication: [AuthenticationMethod] = try await retrieveAllSwarmAuth(using: dependencies)
        let response: UnsubscribeResponse = try await PushNotificationAPI.unsubscribe(
            token: token,
            swarmAuthentication: swarmAuthentication,
            using: dependencies
        )
        
        /// If we successfully unsubscribed for user PNs then remove the cached token
        if response.subResponses.first?.success == true {
            dependencies[defaults: .standard, key: .deviceToken] = nil
        }
    }
    
    private static func retrieveAllSwarmAuth(using dependencies: Dependencies) async throws -> [AuthenticationMethod] {
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        let groupIds: Set<String> = try await dependencies[singleton: .storage].readAsync { db in
            try ClosedGroup
               .select(.threadId)
               .filter(
                   ClosedGroup.Columns.threadId > SessionId.Prefix.group.rawValue &&
                   ClosedGroup.Columns.threadId < SessionId.Prefix.group.endOfRangeString
               )
               .asRequest(of: String.self)
               .fetchSet(db)
        }
        
        return try ([userSessionId.hexString] + groupIds).map {
            try Authentication.with(swarmPublicKey: $0, using: dependencies)
        }
    }
    
    // MARK: - Prepared Requests
    
    public static func subscribe(
        token: Data,
        swarmAuthentication: [AuthenticationMethod],
        using dependencies: Dependencies
    ) async throws -> SubscribeResponse {
        guard !swarmAuthentication.isEmpty else { return SubscribeResponse(subResponses: []) }
        guard dependencies[defaults: .standard, key: .isUsingFullAPNs] else {
            throw NetworkError.invalidPreparedRequest
        }
        
        guard let notificationsEncryptionKey: Data = try? dependencies[singleton: .keychain].getOrGenerateEncryptionKey(
            forKey: .pushNotificationEncryptionKey,
            length: encryptionKeyLength,
            cat: .cat,
            legacyKey: "PNEncryptionKeyKey",
            legacyService: "PNKeyChainService"
        ) else {
            Log.error(.cat, "Unable to retrieve PN encryption key.")
            throw KeychainStorageError.keySpecInvalid
        }
        
        do {
            let request: Network.PreparedRequest<SubscribeResponse> = try Network.PreparedRequest(
                request: Request(
                    method: .post,
                    endpoint: Endpoint.subscribe,
                    body: SubscribeRequest(
                        subscriptions: swarmAuthentication.map { authMethod -> SubscribeRequest.Subscription in
                            SubscribeRequest.Subscription(
                                namespaces: {
                                    switch try? SessionId.Prefix(from: try? authMethod.swarmPublicKey) {
                                        case .group: return [
                                            .groupMessages,
                                            .configGroupKeys,
                                            .configGroupInfo,
                                            .configGroupMembers,
                                            .revokedRetrievableGroupMessages
                                        ]
                                        default: return [
                                            .default,
                                            .configUserProfile,
                                            .configContacts,
                                            .configConvoInfoVolatile,
                                            .configUserGroups
                                        ]
                                    }
                                }(),
                                /// Note: Unfortunately we always need the message content because without the content
                                /// control messages can't be distinguished from visible messages which results in the
                                /// 'generic' notification being shown when receiving things like typing indicator updates
                                includeMessageData: true,
                                serviceInfo: ServiceInfo(
                                    token: token.toHexString()
                                ),
                                notificationsEncryptionKey: notificationsEncryptionKey,
                                authMethod: authMethod,
                                timestamp: (dependencies[cache: .snodeAPI].currentOffsetTimestampMs() / 1000) // Seconds
                            )
                        }
                    ),
                    retryCount: PushNotificationAPI.maxRetryCount
                ),
                responseType: SubscribeResponse.self,
                using: dependencies
            )
            let response: SubscribeResponse = try await request.send(using: dependencies)
            
            zip(response.subResponses, swarmAuthentication).forEach { subResponse, authMethod in
                guard subResponse.success != true else { return }
                
                let swarmPublicKey: String = ((try? authMethod.swarmPublicKey) ?? "INVALID")
                Log.error(.cat, "Couldn't subscribe for push notifications for: \(swarmPublicKey) due to error (\(subResponse.error ?? -1)): \(subResponse.message ?? "nil").")
            }
            
            return response
        }
        catch {
            Log.error(.cat, "Couldn't subscribe for push notifications due to error: \(error).")
            throw error
        }
    }
    
    public static func unsubscribe(
        token: Data,
        swarmAuthentication: [AuthenticationMethod],
        using dependencies: Dependencies
    ) async throws -> UnsubscribeResponse {
        guard !swarmAuthentication.isEmpty else { return UnsubscribeResponse(subResponses: []) }
        
        do {
            let request: Network.PreparedRequest<UnsubscribeResponse> = try Network.PreparedRequest(
                request: Request(
                    method: .post,
                    endpoint: Endpoint.unsubscribe,
                    body: UnsubscribeRequest(
                        subscriptions: swarmAuthentication.map { authMethod -> UnsubscribeRequest.Subscription in
                            UnsubscribeRequest.Subscription(
                                serviceInfo: ServiceInfo(
                                    token: token.toHexString()
                                ),
                                authMethod: authMethod,
                                timestamp: (dependencies[cache: .snodeAPI].currentOffsetTimestampMs() / 1000) // Seconds
                            )
                        }
                    ),
                    retryCount: PushNotificationAPI.maxRetryCount
                ),
                responseType: UnsubscribeResponse.self,
                using: dependencies
            )
            let response: UnsubscribeResponse = try await request.send(using: dependencies)
            
            zip(response.subResponses, swarmAuthentication).forEach { subResponse, authMethod in
                guard subResponse.success != true else { return }
                
                let swarmPublicKey: String = ((try? authMethod.swarmPublicKey) ?? "INVALID")
                Log.error(.cat, "Couldn't unsubscribe for push notifications for: \(swarmPublicKey) due to error (\(subResponse.error ?? -1)): \(subResponse.message ?? "nil").")
            }
            
            return response
        }
        catch {
            Log.error(.cat, "Couldn't unsubscribe for push notifications due to error: \(error).")
            throw error
        }
    }
    
    // MARK: - Notification Handling
    
    public static func processNotification(
        notificationContent: UNNotificationContent,
        using dependencies: Dependencies
    ) -> (data: Data?, metadata: NotificationMetadata, result: ProcessResult) {
        // Make sure the notification is from the updated push server
        guard notificationContent.userInfo["spns"] != nil else {
            return (nil, .invalid, .legacyFailure)
        }
        
        guard let base64EncodedEncString: String = notificationContent.userInfo["enc_payload"] as? String else {
            return (nil, .invalid, .failureNoContent)
        }
        
        // Decrypt and decode the payload
        let notification: BencodeResponse<NotificationMetadata>
        
        do {
            guard let encryptedData: Data = Data(base64Encoded: base64EncodedEncString) else {
                throw CryptoError.invalidBase64EncodedData
            }
            
            let notificationsEncryptionKey: Data = try dependencies[singleton: .keychain].getOrGenerateEncryptionKey(
                forKey: .pushNotificationEncryptionKey,
                length: encryptionKeyLength,
                cat: .cat,
                legacyKey: "PNEncryptionKeyKey",
                legacyService: "PNKeyChainService"
            )
            let decryptedData: Data = try dependencies[singleton: .crypto].tryGenerate(
                .plaintextWithPushNotificationPayload(
                    payload: encryptedData,
                    encKey: notificationsEncryptionKey
                )
            )
            notification = try BencodeDecoder(using: dependencies)
                .decode(BencodeResponse<NotificationMetadata>.self, from: decryptedData)
        }
        catch {
            Log.error(.cat, "Failed to decrypt or decode notification due to error: \(error)")
            return (nil, .invalid, .failure)
        }
        
        // If the metadata says that the message was too large then we should show the generic
        // notification (this is a valid case)
        guard !notification.info.dataTooLong else { return (nil, notification.info, .successTooLong) }
        
        // Check that the body we were given is valid and not empty
        guard
            let notificationData: Data = notification.data,
            notification.info.dataLength == notificationData.count,
            !notificationData.isEmpty
        else {
            Log.error(.cat, "Get notification data failed")
            return (nil, notification.info, .failureNoContent)
        }
        
        // Success, we have the notification content
        return (notificationData, notification.info, .success)
    }
}
