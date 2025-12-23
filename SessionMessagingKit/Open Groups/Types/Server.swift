// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionNetworkingKit
import SessionUtilitiesKit

extension CommunityManager {
    /// The `Server` type is an in-memory store of the current state of all rooms the user is subscribed to on a SOGS
    public struct Server: Codable, Equatable {
        public let server: String
        public let publicKey: String
        public let capabilities: Set<Capability.Variant>
        public let pollFailureCount: Int64
        public let currentUserSessionIds: Set<String>
        
        public let inboxLatestMessageId: Int64
        public let outboxLatestMessageId: Int64
        
        public let rooms: [String: Network.SOGS.Room]
        
        fileprivate init(
            server: String,
            publicKey: String,
            capabilities: Set<Capability.Variant>,
            pollFailureCount: Int64,
            currentUserSessionIds: Set<String>,
            inboxLatestMessageId: Int64,
            outboxLatestMessageId: Int64,
            rooms: [String: Network.SOGS.Room]
        ) {
            self.server = server.lowercased()
            self.publicKey = publicKey
            self.capabilities = capabilities
            self.pollFailureCount = pollFailureCount
            self.currentUserSessionIds = currentUserSessionIds
            self.inboxLatestMessageId = inboxLatestMessageId
            self.outboxLatestMessageId = outboxLatestMessageId
            self.rooms = rooms
        }
    }
}

// MARK: - Convenience

public extension CommunityManager.Server {
    init(
        server: String,
        publicKey: String,
        openGroups: [OpenGroup] = [],
        capabilities: Set<Capability.Variant>? = nil,
        roomMembers: [String: [GroupMember]]? = nil,
        using dependencies: Dependencies
    ) {
        let currentUserSessionIds: Set<String> = CommunityManager.Server.generateCurrentUserSessionIds(
            publicKey: publicKey,
            capabilities: (capabilities ?? []),
            using: dependencies
        )
        
        self.server = server.lowercased()
        self.publicKey = publicKey
        self.capabilities = (capabilities ?? [])
        self.pollFailureCount = (openGroups.map { $0.pollFailureCount }.max() ?? 0)
        self.currentUserSessionIds = currentUserSessionIds

        self.inboxLatestMessageId = (openGroups.map { $0.inboxLatestMessageId }.max() ?? 0)
        self.outboxLatestMessageId = (openGroups.map { $0.outboxLatestMessageId }.max() ?? 0)
        
        self.rooms = openGroups.reduce(into: [:]) { result, next in
            result[next.roomToken] = Network.SOGS.Room(
                openGroup: next,
                members: (roomMembers?[next.roomToken] ?? []),
                currentUserSessionIds: currentUserSessionIds
            )
        }
    }
    
    func with(
        capabilities: Update<Set<Capability.Variant>> = .useExisting,
        inboxLatestMessageId: Update<Int64> = .useExisting,
        outboxLatestMessageId: Update<Int64> = .useExisting,
        rooms: Update<[Network.SOGS.Room]> = .useExisting,
        using dependencies: Dependencies
    ) -> CommunityManager.Server {
        let targetCapabilities: Set<Capability.Variant> = capabilities.or(self.capabilities)
        
        return CommunityManager.Server(
            server: server,
            publicKey: publicKey,
            capabilities: targetCapabilities,
            pollFailureCount: pollFailureCount,
            currentUserSessionIds: CommunityManager.Server.generateCurrentUserSessionIds(
                publicKey: publicKey,
                capabilities: targetCapabilities,
                using: dependencies
            ),
            inboxLatestMessageId: inboxLatestMessageId.or(self.inboxLatestMessageId),
            outboxLatestMessageId: outboxLatestMessageId.or(self.outboxLatestMessageId),
            rooms: {
                switch rooms {
                    case .useExisting: return self.rooms
                    case .set(let updatedRooms):
                        return updatedRooms.reduce(into: [:]) { result, next in
                            result[next.token] = next
                        }
                }
            }()
        )
    }
    
    fileprivate static func generateCurrentUserSessionIds(
        publicKey: String,
        capabilities: Set<Capability.Variant>,
        using dependencies: Dependencies
    ) -> Set<String> {
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        
        /// If the SOGS explicitly **is not** blinded then don't bother generating the blinded ids
        guard capabilities.isEmpty || capabilities.contains(.blind) else {
            return [userSessionId.hexString]
        }
        
        let ed25519SecretKey: [UInt8] = dependencies[cache: .general].ed25519SecretKey
        let userBlinded15SessionId: SessionId? = dependencies[singleton: .crypto]
            .generate(.blinded15KeyPair(serverPublicKey: publicKey, ed25519SecretKey: ed25519SecretKey))
            .map { SessionId(.blinded15, publicKey: $0.publicKey) }
        let userBlinded25SessionId: SessionId? = dependencies[singleton: .crypto]
            .generate(.blinded25KeyPair(serverPublicKey: publicKey, ed25519SecretKey: ed25519SecretKey))
            .map { SessionId(.blinded25, publicKey: $0.publicKey) }
        
        /// Add the users `unblinded` pubkey if we can get it, just for completeness
        let userUnblindedSessionId: SessionId? = dependencies[singleton: .crypto]
            .generate(.ed25519KeyPair(seed: dependencies[cache: .general].ed25519Seed))
            .map { SessionId(.unblinded, publicKey: $0.publicKey) }
        
        return Set([
            userSessionId.hexString,
            userBlinded15SessionId?.hexString,
            userBlinded25SessionId?.hexString,
            userUnblindedSessionId?.hexString
        ].compactMap { $0 })
    }
}

// MARK: - Convenience

internal extension Network.SOGS.Room {
    init(
        openGroup: OpenGroup,
        members: [GroupMember]? = nil,
        currentUserSessionIds: Set<String> = []
    ) {
        let admins: [String] = (members?
            .filter { $0.role == .admin && !$0.isHidden }
            .map { $0.profileId } ?? [])
        let hiddenAdmins: [String]? = members?
            .filter { $0.role == .admin && $0.isHidden }
            .map { $0.profileId }
        let moderators: [String] = (members?
            .filter { $0.role == .moderator && !$0.isHidden }
            .map { $0.profileId } ?? [])
        let hiddenModerators: [String]? = members?
            .filter { $0.role == .moderator && $0.isHidden }
            .map { $0.profileId }
        
        self = Network.SOGS.Room(
            token: openGroup.roomToken,
            name: openGroup.name,
            roomDescription: openGroup.description,
            infoUpdates: openGroup.infoUpdates,
            messageSequence: openGroup.sequenceNumber,
            created: 0,                /// Updated on first poll
            activeUsers: openGroup.userCount,
            activeUsersCutoff: 0,      /// Updated on first poll
            imageId: openGroup.imageId,
            pinnedMessages: nil,       /// Updated on first poll
            admin: (
                !Set(admins).isDisjoint(with: currentUserSessionIds) ||
                !Set(hiddenAdmins ?? []).isDisjoint(with: currentUserSessionIds)
            ),
            globalAdmin: false,        /// Updated on first poll
            admins: admins,            /// Updated on first poll
            hiddenAdmins: hiddenAdmins,
            moderator: (
                !Set(moderators).isDisjoint(with: currentUserSessionIds) ||
                !Set(hiddenModerators ?? []).isDisjoint(with: currentUserSessionIds)
            ),
            globalModerator: false,    /// Updated on first poll
            moderators: moderators,
            hiddenModerators: hiddenModerators,
            read: (openGroup.permissions?.contains(.read) == true),
            defaultRead: false,        /// Updated on first poll
            defaultAccessible: false,  /// Updated on first poll
            write: (openGroup.permissions?.contains(.write) == true),
            defaultWrite: false,       /// Updated on first poll
            upload: (openGroup.permissions?.contains(.upload) == true),
            defaultUpload: false       /// Updated on first poll
        )
    }
}
