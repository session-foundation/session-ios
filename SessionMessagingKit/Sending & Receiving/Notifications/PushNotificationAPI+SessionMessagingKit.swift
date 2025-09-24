// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionNetworkingKit
import SessionUtilitiesKit

public extension Network.PushNotification {
    static func subscribeAll(
        token: Data,
        isForcedUpdate: Bool,
        using dependencies: Dependencies
    ) async throws {
        let hexEncodedToken: String = token.toHexString()
        let oldToken: String? = dependencies[defaults: .standard, key: .deviceToken]
        let lastUploadTime: Double = dependencies[defaults: .standard, key: .lastDeviceTokenUpload]
        let now: TimeInterval = dependencies.dateNow.timeIntervalSince1970
        
        guard isForcedUpdate || hexEncodedToken != oldToken || now - lastUploadTime > tokenExpirationInterval else {
            return Log.info(.pushNotificationAPI, "Device token hasn't changed or expired; no need to re-upload.")
        }
        
        let swarmAuthentication: [AuthenticationMethod] = try await retrieveAllSwarmAuth(using: dependencies)
        let response: SubscribeResponse = try await Network.PushNotification.subscribe(
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
    
    static func unsubscribeAll(
        token: Data,
        using dependencies: Dependencies
    ) async throws {
        let swarmAuthentication: [AuthenticationMethod] = try await retrieveAllSwarmAuth(using: dependencies)
        let response: UnsubscribeResponse = try await Network.PushNotification.unsubscribe(
            token: token,
            swarmAuthentication: swarmAuthentication,
            using: dependencies
        )
        
        /// If we successfully unsubscribed for user PNs then remove the cached token
        if response.subResponses.first?.success == true {
            dependencies[defaults: .standard, key: .deviceToken] = nil
        }
    }
    
    static func retrieveAllSwarmAuth(
        using dependencies: Dependencies
    ) async throws -> [AuthenticationMethod] {
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
}
