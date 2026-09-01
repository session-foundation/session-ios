// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionNetworkingKit
import SessionUtilitiesKit

public extension Network.PushNotification {
    static func subscribeAll(
        token: Data,
        using dependencies: Dependencies
    ) async throws {
        let swarms: [SwarmInfo] = try await retrieveAllSwarms(
            retrievalReason: "subscribe", // stringlint:ignore
            using: dependencies
        )
        let response: SubscribeResponse = try await Network.PushNotification.subscribe(
            token: token,
            swarms: swarms,
            using: dependencies
        )

        /// The user's own swarm is always the first entry (see `retrieveAllSwarms`) so if it failed to subscribe then the device
        /// won't receive push notifications for the user; throw so the caller can retry (and avoid caching state which would
        /// otherwise incorrectly suppress future subscription attempts) rather than treating the subscription as successful
        ///
        /// **Note:** Individual group swarm failures are tolerated (they are logged within `subscribe`) as we don't want a
        /// single bad group to prevent the user (and other groups) from receiving push notifications
        if response.subResponses.first?.success != true {
            throw NetworkError.explicit(
                "Failed to subscribe the user swarm for push notifications (error: \(response.subResponses.first?.error ?? -1))." // stringlint:ignore
            )
        }
    }
    
    static func unsubscribeAll(
        token: Data,
        using dependencies: Dependencies
    ) async throws {
        let swarms: [SwarmInfo] = try await retrieveAllSwarms(
            retrievalReason: "unsubscribe", // stringlint:ignore
            using: dependencies
        )
        let response: UnsubscribeResponse = try await Network.PushNotification.unsubscribe(
            token: token,
            swarms: swarms,
            using: dependencies
        )
        
        /// If we successfully unsubscribed for user PNs then remove the cached token
        if response.subResponses.first?.success == true {
            dependencies[defaults: .standard, key: .deviceToken] = nil
        }
    }
    
    static func retrieveAllSwarms(
        retrievalReason: String,
        using dependencies: Dependencies
    ) async throws -> [(sessionId: SessionId, authMethod: AuthenticationMethod)] {
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        let groupIds: Set<SessionId> = try await Set(dependencies[singleton: .storage]
            .read { db in
                try ClosedGroup
                    .select(.threadId)
                    .filter(
                        ClosedGroup.Columns.threadId > SessionId.Prefix.group.rawValue &&
                        ClosedGroup.Columns.threadId < SessionId.Prefix.group.endOfRangeString
                    )
                    .asRequest(of: String.self)
                    .fetchSet(db)
            }
            .map { SessionId(.group, hex: $0) })
        
        return ([userSessionId] + groupIds).compactMap { sessionId in
            do {
                let authMethod: AuthenticationMethod = try Authentication.with(
                    swarmPublicKey: sessionId.hexString,
                    using: dependencies
                )
                
                /// We need to try to generate a signature as it's possible we could retrieve auth data but fail to generate the signature
                /// which would result in the entire subscription request failing rather than just the one for this group
                _ = try authMethod.generateSignature(with: [], using: dependencies)
                
                return (sessionId, authMethod)
            }
            catch {
                Log.warn(.pushNotificationAPI, "Skipping attempt to \(retrievalReason) for push notifications for \(sessionId.hexString) due to error: \(error).")
                return nil
            }
        }
    }
}
