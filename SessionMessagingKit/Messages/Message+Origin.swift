// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionNetworkingKit
import SessionUtilitiesKit

public extension Message {
    enum Origin: Codable, Hashable {
        case swarm(
            publicKey: String,
            namespace: Network.SnodeAPI.Namespace,
            serverHash: String,
            serverTimestampMs: Int64,
            serverExpirationTimestamp: TimeInterval
        )
        case community(
            openGroupId: String,
            sender: String,
            posted: TimeInterval,
            messageServerId: Int64,
            whisper: Bool,
            whisperMods: Bool,
            whisperTo: String?
        )
        case communityInbox(
            posted: TimeInterval,
            messageServerId: Int64,
            serverPublicKey: String,
            senderId: String,
            recipientId: String
        )
        
        public var isConfigNamespace: Bool {
            switch self {
                case .swarm(_, let namespace, _, _, _): return namespace.isConfigNamespace
                default: return false
            }
        }
        
        public var isRevokedRetrievableNamespace: Bool {
            switch self {
                case .swarm(_, let namespace, _, _, _): return (namespace == .revokedRetrievableGroupMessages)
                default: return false
            }
        }
    }
}
