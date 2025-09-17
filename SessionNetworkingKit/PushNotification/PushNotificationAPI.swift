// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import UserNotifications
import SessionUtilitiesKit

public extension Network.PushNotification {
    static func subscribe(
        token: Data,
        swarmAuthentication: [AuthenticationMethod],
        using dependencies: Dependencies
    ) async throws -> SubscribeResponse {
        guard dependencies[defaults: .standard, key: .isUsingFullAPNs] else {
            throw NetworkError.invalidPreparedRequest
        }
        
        guard let notificationsEncryptionKey: Data = try? dependencies[singleton: .keychain].getOrGenerateEncryptionKey(
            forKey: .pushNotificationEncryptionKey,
            length: encryptionKeyLength,
            cat: .pushNotificationAPI,
            legacyKey: "PNEncryptionKeyKey",
            legacyService: "PNKeyChainService"
        ) else {
            Log.error(.pushNotificationAPI, "Unable to retrieve PN encryption key.")
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
                                timestamp: (dependencies[cache: .storageServer].currentOffsetTimestampMs() / 1000) // Seconds
                            )
                        }
                    ),
                    retryCount: Network.PushNotification.maxRetryCount
                ),
                responseType: SubscribeResponse.self,
                using: dependencies
            )
            let response: SubscribeResponse = try await request.send(using: dependencies)
                        
            zip(response.subResponses, swarmAuthentication).forEach { subResponse, authMethod in
                guard subResponse.success != true else { return }
                
                let swarmPublicKey: String = ((try? authMethod.swarmPublicKey) ?? "INVALID")
                Log.error(.pushNotificationAPI, "Couldn't subscribe for push notifications for: \(swarmPublicKey) due to error (\(subResponse.error ?? -1)): \(subResponse.message ?? "nil").")
            }
                
            return response
        }
        catch {
            Log.error(.pushNotificationAPI, "Couldn't subscribe for push notifications due to error: \(error).")
            throw error
        }
    }
    
    static func unsubscribe(
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
                                timestamp: (dependencies[cache: .storageServer].currentOffsetTimestampMs() / 1000) // Seconds
                            )
                        }
                    ),
                    retryCount: Network.PushNotification.maxRetryCount
                ),
                responseType: UnsubscribeResponse.self,
                using: dependencies
            )
            let response: UnsubscribeResponse = try await request.send(using: dependencies)
            
            zip(response.subResponses, swarmAuthentication).forEach { subResponse, authMethod in
                guard subResponse.success != true else { return }
                
                let swarmPublicKey: String = ((try? authMethod.swarmPublicKey) ?? "INVALID")
                Log.error(.pushNotificationAPI, "Couldn't unsubscribe for push notifications for: \(swarmPublicKey) due to error (\(subResponse.error ?? -1)): \(subResponse.message ?? "nil").")
            }
            
            return response
        }
        catch {
            Log.error(.pushNotificationAPI, "Couldn't unsubscribe for push notifications due to error: \(error).")
            throw error
        }
    }
    
    // MARK: - Notification Handling
    
    static func processNotification(
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
                cat: .pushNotificationAPI,
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
            Log.error(.pushNotificationAPI, "Failed to decrypt or decode notification due to error: \(error)")
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
            Log.error(.pushNotificationAPI, "Get notification data failed")
            return (nil, notification.info, .failureNoContent)
        }
        
        // Success, we have the notification content
        return (notificationData, notification.info, .success)
    }
}
