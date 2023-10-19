// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import DifferenceKit
import SessionSnodeKit
import SessionUtilitiesKit

public struct ClosedGroup: Codable, Equatable, Hashable, Identifiable, FetchableRecord, PersistableRecord, TableRecord, ColumnExpressible {
    public static var databaseTableName: String { "closedGroup" }
    internal static let threadForeignKey = ForeignKey([Columns.threadId], to: [SessionThread.Columns.id])
    public static let thread = belongsTo(SessionThread.self, using: threadForeignKey)
    internal static let keyPairs = hasMany(
        ClosedGroupKeyPair.self,
        using: ClosedGroupKeyPair.closedGroupForeignKey
    )
    public static let members = hasMany(GroupMember.self, using: GroupMember.closedGroupForeignKey)
    
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case threadId
        case name
        case groupDescription
        case formationTimestamp
        
        case displayPictureUrl
        case displayPictureFilename
        case displayPictureEncryptionKey
        case lastDisplayPictureUpdate
        
        case shouldPoll
        case groupIdentityPrivateKey
        case authData
        case invited
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
    
    /// The URL from which to fetch the groups's display picture.
    public let displayPictureUrl: String?

    /// The file name of the groups's display picture on local storage.
    public let displayPictureFilename: String?

    /// The key with which the display picture is encrypted.
    public let displayPictureEncryptionKey: Data?
    
    /// The timestamp (in seconds since epoch) that the display picture was last updated
    public let lastDisplayPictureUpdate: TimeInterval?
    
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
    
    // MARK: - Relationships
    
    public var thread: QueryInterfaceRequest<SessionThread> {
        request(for: ClosedGroup.thread)
    }
    
    public var keyPairs: QueryInterfaceRequest<ClosedGroupKeyPair> {
        request(for: ClosedGroup.keyPairs)
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
        displayPictureFilename: String? = nil,
        displayPictureEncryptionKey: Data? = nil,
        lastDisplayPictureUpdate: TimeInterval? = nil,
        shouldPoll: Bool?,
        groupIdentityPrivateKey: Data? = nil,
        authData: Data? = nil,
        invited: Bool?
    ) {
        self.threadId = threadId
        self.name = name
        self.groupDescription = groupDescription
        self.formationTimestamp = formationTimestamp
        self.displayPictureUrl = displayPictureUrl
        self.displayPictureFilename = displayPictureFilename
        self.displayPictureEncryptionKey = displayPictureEncryptionKey
        self.lastDisplayPictureUpdate = lastDisplayPictureUpdate
        self.shouldPoll = shouldPoll
        self.groupIdentityPrivateKey = groupIdentityPrivateKey
        self.authData = authData
        self.invited = invited
    }
}

// MARK: - GRDB Interactions

public extension ClosedGroup {
    func fetchLatestKeyPair(_ db: Database) throws -> ClosedGroupKeyPair? {
        return try keyPairs
            .order(ClosedGroupKeyPair.Columns.receivedTimestamp.desc)
            .fetchOne(db)
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
        case encryptionKeys
        case libSessionState
        case thread
        case userGroup
    }
    
    static func approveGroup(
        _ db: Database,
        group: ClosedGroup,
        calledFromConfigHandling: Bool,
        using dependencies: Dependencies
    ) throws {
        guard let userED25519KeyPair: KeyPair = Identity.fetchUserEd25519KeyPair(db, using: dependencies) else {
            throw MessageReceiverError.noUserED25519KeyPair
        }
        
        if group.invited == true || group.shouldPoll != true {
            try ClosedGroup
                .filter(id: group.id)
                .updateAllAndConfig(
                    db,
                    ClosedGroup.Columns.invited.set(to: false),
                    ClosedGroup.Columns.shouldPoll.set(to: true),
                    calledFromConfig: calledFromConfigHandling,
                    using: dependencies
                )
        }
        
        try SessionUtil.createGroupState(
            groupSessionId: SessionId(.group, hex: group.id),
            userED25519KeyPair: userED25519KeyPair,
            groupIdentityPrivateKey: group.groupIdentityPrivateKey,
            authData: group.authData,
            shouldLoadState: true,
            using: dependencies
        )
        
        // Start polling
        dependencies[singleton: .groupsPoller].startIfNeeded(for: group.id, using: dependencies)
    }
    
    static func removeData(
        _ db: Database,
        threadIds: [String],
        dataToRemove: [RemovableGroupData],
        calledFromConfigHandling: Bool,
        using dependencies: Dependencies
    ) throws {
        guard !threadIds.isEmpty && !dataToRemove.isEmpty else { return }
        
        struct ThreadIdVariant: Decodable, FetchableRecord {
            let id: String
            let variant: SessionThread.Variant
        }
        
        // Remove the group from the database and unsubscribe from PNs
        let userSessionId: SessionId = getUserSessionId(db, using: dependencies)
        let threadVariants: [ThreadIdVariant] = try {
            guard
                dataToRemove.contains(.pushNotifications) ||
                (dataToRemove.contains(.userGroup) && !calledFromConfigHandling) ||
                (dataToRemove.contains(.libSessionState) && !calledFromConfigHandling)
            else { return [] }
            
            return try SessionThread
                .select(.id, .variant)
                .filter(ids: threadIds)
                .asRequest(of: ThreadIdVariant.self)
                .fetchAll(db)
        }()
        
        // This data isn't located in the database so we can't perform bulk actions
        if !dataToRemove.asSet().intersection([.poller, .pushNotifications, .libSessionState]).isEmpty {
            threadIds.forEach { threadId in
                if dataToRemove.contains(.poller) {
                    dependencies[singleton: .groupsPoller].stopPolling(for: threadId)
                }
                
                if dataToRemove.contains(.poller) {
                    threadVariants.forEach { threadIdVariant in
                        switch threadIdVariant.variant {
                            case .legacyGroup:
                                try? PushNotificationAPI
                                    .preparedUnsubscribeFromLegacyGroup(
                                        legacyGroupId: threadId,
                                        userSessionId: userSessionId
                                    )
                                    .send(using: dependencies)
                                    .sinkUntilComplete()
                                
                            case .group:
                                break
                                
                            default: break
                        }
                    }
                }
                
                // Ignore if called from the config handling
                if dataToRemove.contains(.libSessionState) && !calledFromConfigHandling {
                    threadVariants
                        .filter { $0.variant == .group }
                        .forEach { threadIdVariant in
                            SessionUtil.removeGroupStateIfNeeded(
                                db,
                                groupSessionId: SessionId(.group, hex: threadIdVariant.id),
                                using: dependencies
                            )
                        }
                }
            }
        }
        
        // Remove database-located data
        if dataToRemove.contains(.encryptionKeys) {
            try ClosedGroupKeyPair
                .filter(threadIds.contains(ClosedGroupKeyPair.Columns.threadId))
                .deleteAll(db)
        }
        
        if dataToRemove.contains(.messages) {
            try Interaction
                .filter(threadIds.contains(Interaction.Columns.threadId))
                .deleteAll(db)
        }
        
        if dataToRemove.contains(.members) {
            try GroupMember
                .filter(threadIds.contains(GroupMember.Columns.groupId))
                .deleteAll(db)
        }
        
        // If we remove the poller but don't remove the thread then update the group so it doesn't poll
        // on the next launch
        if dataToRemove.contains(.poller) && !dataToRemove.contains(.thread) {
            try ClosedGroup
                .filter(ids: threadIds)
                .updateAllAndConfig(
                    db,
                    ClosedGroup.Columns.shouldPoll.set(to: false),
                    using: dependencies
                )
        }
        
        if dataToRemove.contains(.thread) {
            try SessionThread   // Intentionally use `deleteAll` here as this gets triggered via `deleteOrLeave`
                .filter(ids: threadIds)
                .deleteAll(db)
        }
        
        // Ignore if called from the config handling
        if dataToRemove.contains(.userGroup) && !calledFromConfigHandling {
            try SessionUtil.remove(
                db,
                legacyGroupIds: threadVariants
                    .filter { $0.variant == .legacyGroup }
                    .map { $0.id },
                using: dependencies
            )
            
            try SessionUtil.remove(
                db,
                groupSessionIds: threadVariants
                    .filter { $0.variant == .group }
                    .map { $0.id },
                using: dependencies
            )
        }
    }
}

// MARK: - ClosedGroup.MessageInfo

public extension ClosedGroup {
    enum MessageInfo: Codable {
        case updatedName(String)
        case updatedNameFallback
        case updatedDisplayPicture
        case addedUsers(names: [String])
        case removedUsers(names: [String])
        case memberLeft(name: String)
        case promotedUsers(names: [String])
        
        var previewText: String {
            switch self {
                case .updatedName(let name):
                    return String(
                        format: "GROUP_MESSAGE_INFO_NAME_UPDATED_TO".localized(),
                        name
                    )
                    
                case .updatedNameFallback: return "GROUP_MESSAGE_INFO_NAME_UPDATED".localized()
                case .updatedDisplayPicture: return "GROUP_MESSAGE_INFO_PICTURE_UPDATED".localized()
            }
        }
        
        var infoString: String? {
            guard let messageInfoData: Data = try? JSONEncoder().encode(self) else { return nil }
            
            return String(data: messageInfoData, encoding: .utf8)
        }
    }
}

public extension [ClosedGroup.RemovableGroupData] {
    static var allData: [ClosedGroup.RemovableGroupData] { ClosedGroup.RemovableGroupData.allCases }
    static var noData: [ClosedGroup.RemovableGroupData] { [] }
}
