// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import DifferenceKit
import SessionUIKit
import SessionNetworkingKit
import SessionUtilitiesKit

public struct ClosedGroup: Codable, Equatable, Hashable, Identifiable, FetchableRecord, PersistableRecord, TableRecord, ColumnExpressible {
    public static var databaseTableName: String { "closedGroup" }
    internal static let threadForeignKey = ForeignKey([Columns.threadId], to: [SessionThread.Columns.id])
    public static let thread = belongsTo(SessionThread.self, using: threadForeignKey)
    public static let members = hasMany(GroupMember.self, using: GroupMember.closedGroupForeignKey)
    
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case threadId
        case name
        case groupDescription
        case formationTimestamp
        
        case displayPictureUrl
        case displayPictureEncryptionKey
        
        case shouldPoll
        case groupIdentityPrivateKey
        case authData
        case invited
        case expired
    }
    
    public var id: String { threadId }  // Identifiable
    public var publicKey: String { threadId }

    /// The id for the thread this closed group belongs to
    ///
    /// **Note:** This value will always be publicKey for the closed group
    public let threadId: String
    public let name: String
    public let groupDescription: String?
    public let formationTimestamp: TimeInterval
    
    /// The URL from which to fetch the groups's display picture
    ///
    /// **Note:** This won't be updated until the display picture has actually been downloaded
    public let displayPictureUrl: String?

    /// The key with which the display picture is encrypted.
    public let displayPictureEncryptionKey: Data?
    
    /// A flag indicating whether we should poll for messages in this group
    public let shouldPoll: Bool?
    
    /// The private key for performing admin actions on this group
    public let groupIdentityPrivateKey: Data?
    
    /// The unique authData for the current user within the group
    ///
    /// **Note:** This will be `null` if the `groupIdentityPrivateKey`  is set
    public let authData: Data?
    
    /// A flag indicating whether this group is in the "invite" state
    public let invited: Bool?
    
    /// A flag indicating whether this group is in the "expired" state (ie. it's config messages no longer exist)
    public let expired: Bool?
    
    // MARK: - Relationships
    
    public var thread: QueryInterfaceRequest<SessionThread> {
        request(for: ClosedGroup.thread)
    }
    
    public var allMembers: QueryInterfaceRequest<GroupMember> {
        request(for: ClosedGroup.members)
    }
    
    public var members: QueryInterfaceRequest<GroupMember> {
        request(for: ClosedGroup.members)
            .filter(GroupMember.Columns.role == GroupMember.Role.standard)
    }
    
    public var zombies: QueryInterfaceRequest<GroupMember> {
        request(for: ClosedGroup.members)
            .filter(GroupMember.Columns.role == GroupMember.Role.zombie)
    }
    
    public var moderators: QueryInterfaceRequest<GroupMember> {
        request(for: ClosedGroup.members)
            .filter(GroupMember.Columns.role == GroupMember.Role.moderator)
    }
    
    public var admins: QueryInterfaceRequest<GroupMember> {
        request(for: ClosedGroup.members)
            .filter(GroupMember.Columns.role == GroupMember.Role.admin)
    }
    
    // MARK: - Initialization
    
    public init(
        threadId: String,
        name: String,
        groupDescription: String? = nil,
        formationTimestamp: TimeInterval,
        displayPictureUrl: String? = nil,
        displayPictureEncryptionKey: Data? = nil,
        shouldPoll: Bool?,
        groupIdentityPrivateKey: Data? = nil,
        authData: Data? = nil,
        invited: Bool?,
        expired: Bool? = false
    ) {
        self.threadId = threadId
        self.name = name
        self.groupDescription = groupDescription
        self.formationTimestamp = formationTimestamp
        self.displayPictureUrl = displayPictureUrl
        self.displayPictureEncryptionKey = displayPictureEncryptionKey
        self.shouldPoll = shouldPoll
        self.groupIdentityPrivateKey = groupIdentityPrivateKey
        self.authData = authData
        self.invited = invited
        self.expired = expired
    }
}

// MARK: - Search Queries

public extension ClosedGroup {
    struct FullTextSearch: Decodable, ColumnExpressible {
        public typealias Columns = CodingKeys
        public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
            case name
        }
        
        let name: String
    }
}

// MARK: - Convenience

public extension ClosedGroup {
    enum LeaveType {
        case standard
        case silent
        case forced
    }
    
    enum RemovableGroupData: CaseIterable {
        case poller
        case pushNotifications
        case messages
        case members
        case authDetails
        case libSessionState
        case thread
        case userGroup
    }
    
    static func approveGroupIfNeeded(
        _ db: ObservingDatabase,
        group: ClosedGroup,
        using dependencies: Dependencies
    ) throws {
        /// Update the `USER_GROUPS` config
        try? LibSession.update(
            db,
            groupSessionId: group.id,
            invited: false,
            using: dependencies
        )
        
        /// If we don't have auth data for the group then no need to make any other changes (this can happen if we
        /// have synced an updated group that the user was kicked from or was already destroyed)
        guard group.authData != nil || group.groupIdentityPrivateKey != nil else {
            /// Update the database state before we finish up
            if group.invited == true {
                try ClosedGroup
                    .filter(id: group.id)
                    .updateAllAndConfig(
                        db,
                        ClosedGroup.Columns.invited.set(to: false),
                        using: dependencies
                    )
            }
            return
        }
        
        /// Update the database state if needed
        if group.invited == true || group.shouldPoll != true {
            try ClosedGroup
                .filter(id: group.id)
                .updateAllAndConfig(
                    db,
                    ClosedGroup.Columns.invited.set(to: false),
                    ClosedGroup.Columns.shouldPoll.set(to: true),
                    using: dependencies
                )
            
            db.addEvent(group.id, forKey: .messageRequestAccepted)
        }
        
        /// Load the group state into the `LibSession.Cache` if needed
        dependencies.mutate(cache: .libSession) { cache in
            let groupSessionId: SessionId = .init(.group, hex: group.id)
            
            guard
                !cache.hasConfig(for: .groupKeys, sessionId: groupSessionId) ||
                !cache.hasConfig(for: .groupInfo, sessionId: groupSessionId) ||
                !cache.hasConfig(for: .groupMembers, sessionId: groupSessionId)
            else { return }
            
            _ = try? cache.createAndLoadGroupState(
                groupSessionId: groupSessionId,
                userED25519SecretKey: dependencies[cache: .general].ed25519SecretKey,
                groupIdentityPrivateKey: group.groupIdentityPrivateKey
            )
        }
        
        /// Start the poller
        Task.detached(priority: .userInitiated) { [manager = dependencies[singleton: .groupPollerManager]] in
            await manager.getOrCreatePoller(for: group.id).startIfNeeded()
        }
        
        /// Subscribe for group push notifications
        if let token: String = dependencies[defaults: .standard, key: .deviceToken] {
            Task.detached(priority: .userInitiated) {
                try? await PushNotificationAPI.subscribe(
                    token: Data(hex: token),
                    swarmAuthentication: [
                        try? Authentication.with(swarmPublicKey: group.id, using: dependencies)
                    ].compactMap { $0 },
                    using: dependencies
                )
            }
        }
    }
    
    static func removeData(
        _ db: ObservingDatabase,
        threadIds: [String],
        dataToRemove: [RemovableGroupData],
        using dependencies: Dependencies
    ) throws {
        guard !threadIds.isEmpty && !dataToRemove.isEmpty else { return }
        
        struct ThreadIdVariant: Decodable, FetchableRecord {
            let id: String
            let variant: SessionThread.Variant
        }
        
        // Remove the group from the database and unsubscribe from PNs
        let threadVariants: [ThreadIdVariant] = try {
            guard
                dataToRemove.contains(.pushNotifications) ||
                dataToRemove.contains(.userGroup) ||
                dataToRemove.contains(.libSessionState)
            else { return [] }
            
            return try SessionThread
                .select(.id, .variant)
                .filter(ids: threadIds)
                .asRequest(of: ThreadIdVariant.self)
                .fetchAll(db)
        }()
        let messageRequestMap: [String: Bool] = dependencies.mutate(cache: .libSession) { libSession in
            threadVariants
                .map { ($0.id, libSession.isMessageRequest(threadId: $0.id, threadVariant: $0.variant)) }
                .reduce(into: [:]) { result, next in result[next.0] = next.1 }
        }
        
        // This data isn't located in the database so we can't perform bulk actions
        if !dataToRemove.asSet().intersection([.poller, .pushNotifications, .libSessionState]).isEmpty {
            threadIds.forEach { threadId in
                if dataToRemove.contains(.poller) {
                    Task { [manager = dependencies[singleton: .groupPollerManager]] in
                        await manager.stopAndRemovePoller(for: threadId)
                    }
                }
                
                if dataToRemove.contains(.libSessionState) {
                    /// Wait until after the transaction completes before removing the group state (this is needed as it's possible that
                    /// we are already mutating the `libSessionCache` when this function gets called)
                    db.afterCommit {
                        let groupVariants: [ThreadIdVariant] = threadVariants.filter {
                            $0.variant == .group
                        }
                        
                        guard !groupVariants.isEmpty else { return }
                        
                        dependencies[singleton: .storage].writeAsync { db in
                            groupVariants.forEach { threadIdVariant in
                                LibSession.removeGroupStateIfNeeded(
                                    db,
                                    groupSessionId: SessionId(.group, hex: threadIdVariant.id),
                                    using: dependencies
                                )
                            }
                        }
                    }
                }
            }
            
            /// Bulk unsubscripe from updated groups being removed
            if dataToRemove.contains(.pushNotifications) && threadVariants.contains(where: { $0.variant == .group }) {
                if let token: String = dependencies[defaults: .standard, key: .deviceToken] {
                    Task.detached(priority: .userInitiated) { [dependencies] in
                        try? await PushNotificationAPI.unsubscribe(
                            token: Data(hex: token),
                            swarmAuthentication: threadVariants
                                .filter { $0.variant == .group }
                                .compactMap { try? Authentication.with(swarmPublicKey: $0.id, using: dependencies) },
                            using: dependencies
                        )
                    }
                }
            }
        }
        
        if dataToRemove.contains(.authDetails) {
            /// Need to explicitly trigger config updates here because relying on `updateAllAndConfig` will result in an
            /// error being thrown by `libSession` because it'll attempt to update the `GROUP_INFO` config if the user
            /// was an admin (which will fail because we have removed the auth data for the group)
            try ClosedGroup
                .filter(ids: threadIds)
                .updateAll(
                    db,
                    ClosedGroup.Columns.groupIdentityPrivateKey.set(to: nil),
                    ClosedGroup.Columns.authData.set(to: nil)
                )
        }
        
        if dataToRemove.contains(.messages) {
            struct InteractionThreadInfo: Codable, FetchableRecord, Hashable {
                let id: Int64
                let threadId: String
            }
            
            let interactionInfo: Set<InteractionThreadInfo> = try Interaction
                .select(.id, .threadId)
                .filter(threadIds.contains(Interaction.Columns.threadId))
                .asRequest(of: InteractionThreadInfo.self)
                .fetchSet(db)
            try Interaction.deleteAll(db, ids: interactionInfo.map { $0.id })
            
            interactionInfo.forEach { db.addMessageEvent(id: $0.id, threadId: $0.threadId, type: .deleted) }
            
            /// Delete any `MessageDeduplication` entries that we want to reprocess if the member gets
            /// re-invited to the group with historic access (these are repeatable records so won't cause issues if we re-run them)
            try MessageDeduplication.deleteIfNeeded(db, threadIds: threadIds, using: dependencies)
            
            /// Also want to delete the `SnodeReceivedMessageInfo` so if the member gets re-invited to the group with
            /// historic access they can re-download and process all of the old messages
            try threadIds.forEach { threadId in
                try SnodeReceivedMessageInfo
                    .filter(SnodeReceivedMessageInfo.Columns.swarmPublicKey == threadId)
                    .deleteAll(db)
            }
        }
        
        if dataToRemove.contains(.members) {
            try GroupMember
                .filter(threadIds.contains(GroupMember.Columns.groupId))
                .deleteAll(db)
        }
        
        // If we remove the poller but don't remove the thread then update the group so it doesn't poll
        // on the next launch
        if dataToRemove.contains(.poller) && !dataToRemove.contains(.thread) {
            /// Should not call `updateAllAndConfig` here as that can result in an error being thrown by `libSession` if the current
            /// user was an admin as it'll attempt, and fail, to update the `GROUP_INFO` because we have already removed the auth data
            try ClosedGroup
                .filter(ids: threadIds)
                .updateAll(
                    db,
                    ClosedGroup.Columns.shouldPoll.set(to: false)
                )
        }
        
        if dataToRemove.contains(.thread) {
            try SessionThread   // Intentionally use `deleteAll` here as this gets triggered via `deleteOrLeave`
                .filter(ids: threadIds)
                .deleteAll(db)
            
            threadIds.forEach { id in
                db.addConversationEvent(id: id, type: .deleted)
                
                /// Need an explicit event for deleting a message request to trigger a home screen update
                if messageRequestMap[id] == true {
                    db.addEvent(.messageRequestDeleted)
                }
            }
        }
        
        // Ignore if called from the config handling
        if dataToRemove.contains(.userGroup) {
            try LibSession.remove(
                db,
                legacyGroupIds: threadVariants
                    .filter { $0.variant == .legacyGroup }
                    .map { $0.id },
                using: dependencies
            )
            
            try LibSession.remove(
                db,
                groupSessionIds: threadVariants
                    .filter { $0.variant == .group }
                    .map { SessionId(.group, hex: $0.id) },
                using: dependencies
            )
        }
    }
}

// MARK: - ClosedGroup.MessageInfo

public extension ClosedGroup {
    enum MessageInfo: Codable {
        case invited(String, String)
        case invitedFallback(String)
        case invitedAdmin(String, String)
        case invitedAdminFallback(String)
        case updatedName(String)
        case updatedNameFallback
        case updatedDisplayPicture
        
        /// If the added users contain the current user then `names` should be sorted to have the current users name first
        case addedUsers(hasCurrentUser: Bool, names: [String], historyShared: Bool)
        case removedUsers(hasCurrentUser: Bool, names: [String])
        case memberLeft(wasCurrentUser: Bool, name: String)
        case promotedUsers(hasCurrentUser: Bool, names: [String])
        
        var previewText: String {
            switch self {
                case .invited(let adminName, let groupName):
                    return "messageRequestGroupInvite"
                        .put(key: "name", value: adminName)
                        .put(key: "group_name", value: groupName)
                        .localized()
                
                case .invitedFallback: return "groupInviteYou".localized()
                
                case .invitedAdmin(let adminName, let groupName):
                    return "groupInviteReinvite"
                        .put(key: "name", value: adminName)
                        .put(key: "group_name", value: groupName)
                        .localized()
                    
                case .invitedAdminFallback(let groupName):
                    return "groupInviteReinviteYou"
                        .put(key: "group_name", value: groupName)
                        .localized()
                    
                case .updatedName(let name):
                    return "groupNameNew"
                        .put(key: "group_name", value: name)
                        .localized()
                    
                case .updatedNameFallback: return "groupNameUpdated".localized()
                case .updatedDisplayPicture: return "groupDisplayPictureUpdated".localized()
                
                case .addedUsers(false, let names, false) where names.count > 2:
                    return "groupMemberNewMultiple"
                        .put(key: "name", value: names[0])
                        .put(key: "count", value: names.count - 1)
                        .localized()
                    
                case .addedUsers(false, let names, true) where names.count > 2:
                    return "groupMemberNewHistoryMultiple"
                        .put(key: "name", value: names[0])
                        .put(key: "count", value: names.count - 1)
                        .localized()
                    
                case .addedUsers(true, let names, false) where names.count > 2:
                    return "groupInviteYouAndMoreNew"
                        .put(key: "count", value: names.count - 1)
                        .localized()
                    
                case .addedUsers(true, let names, true) where names.count > 2:
                    return "groupMemberNewYouHistoryMultiple"
                        .put(key: "count", value: names.count - 1)
                        .localized()
                    
                case .addedUsers(false, let names, false) where names.count == 2:
                    return "groupMemberNewTwo"
                        .put(key: "name", value: names[0])
                        .put(key: "other_name", value: names[1])
                        .localized()
                    
                case .addedUsers(false, let names, true) where names.count == 2:
                    return "groupMemberNewHistoryTwo"
                        .put(key: "name", value: names[0])
                        .put(key: "other_name", value: names[1])
                        .localized()
                    
                case .addedUsers(true, let names, false) where names.count == 2:
                    return "groupInviteYouAndOtherNew"
                        .put(key: "other_name", value: names[1])    // The current user will always be the first name
                        .localized()
                    
                case .addedUsers(true, let names, true) where names.count == 2:
                    return "groupMemberNewYouHistoryTwo"
                        .put(key: "other_name", value: names[1])          // The current user will always be the first name
                        .localized()
                    
                case .addedUsers(false, let names, false):
                    return "groupMemberNew"
                        .put(key: "name", value: names.first ?? "anonymous".localized())
                        .localized()
                    
                case .addedUsers(false, let names, true):
                    return "groupMemberNewHistory"
                        .put(key: "name", value: names.first ?? "anonymous".localized())
                        .localized()
                    
                case .addedUsers(true, _, false): return "groupInviteYou".localized()
                case .addedUsers(true, _, true): return "groupInviteYouHistory".localized()
                    
                case .removedUsers(false, let names) where names.count > 2:
                    return "groupRemovedMultiple"
                        .put(key: "name", value: names[0])
                        .put(key: "count", value: names.count - 1)
                        .localized()
                    
                case .removedUsers(true, let names) where names.count > 2:
                    return "groupRemovedYouMultiple"
                        .put(key: "count", value: names.count - 1)
                        .localized()
                    
                case .removedUsers(false, let names) where names.count == 2:
                    return "groupRemovedTwo"
                        .put(key: "name", value: names[0])
                        .put(key: "other_name", value: names[1])
                        .localized()
                    
                case .removedUsers(true, let names) where names.count == 2:
                    return "groupRemovedYouTwo"
                        .put(key: "other_name", value: names[1])          // The current user will always be the first name
                        .localized()
                    
                case .removedUsers(false, let names):
                    return "groupRemoved"
                        .put(key: "name", value: names.first ?? "anonymous".localized())
                        .localized()
                
                case .removedUsers(true, _): return "groupRemovedYouGeneral".localized()
                    
                case .memberLeft(false, let name):
                    return "groupMemberLeft"
                        .put(key: "name", value: name)
                        .localized()
                
                case .memberLeft(true, _): return "groupMemberYouLeft".localized()
                    
                case .promotedUsers(false, let names) where names.count > 2:
                    return "adminMorePromotedToAdmin"
                        .put(key: "name", value: names[0])
                        .put(key: "count", value: names.count - 1)
                        .localized()
                    
                case .promotedUsers(true, let names) where names.count > 2:
                    return "groupPromotedYouMultiple"
                        .put(key: "count", value: names.count - 1)
                        .localized()
                    
                case .promotedUsers(false, let names) where names.count == 2:
                    return "adminTwoPromotedToAdmin"
                        .put(key: "name", value: names[0])
                        .put(key: "other_name", value: names[1])
                        .localized()
                    
                case .promotedUsers(true, let names) where names.count == 2:
                    return "groupPromotedYouTwo"
                        .put(key: "other_name", value: names[1])              // The current user will always be the first name
                        .localized()
                    
                case .promotedUsers(false, let names):
                    return "adminPromotedToAdmin"
                        .put(key: "name", value: names.first ?? "anonymous".localized())
                        .localized()
                    
                case .promotedUsers(true, _): return "groupPromotedYou".localized()
            }
        }
        
        func infoString(using dependencies: Dependencies) -> String? {
            guard let messageInfoData: Data = try? JSONEncoder(using: dependencies).encode(self) else { return nil }
            
            return String(data: messageInfoData, encoding: .utf8)
        }
    }
}

public extension Collection where Element == (String, Profile?) {
    func sortedById(userSessionId: SessionId) -> [Element] {
        return sorted { lhs, rhs in
            guard lhs.0 != userSessionId.hexString else { return true }
            guard rhs.0 != userSessionId.hexString else { return false }
            
            return (lhs.0 < rhs.0)
        }
    }
}

public extension Collection where Element == String {
    func sortedById(userSessionId: SessionId) -> [Element] {
        return sorted { lhs, rhs in
            guard lhs != userSessionId.hexString else { return true }
            guard rhs != userSessionId.hexString else { return false }
            
            return (lhs < rhs)
        }
    }
}

public extension [ClosedGroup.RemovableGroupData] {
    static var allData: [ClosedGroup.RemovableGroupData] { ClosedGroup.RemovableGroupData.allCases }
    static var noData: [ClosedGroup.RemovableGroupData] { [] }
}
