// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import DifferenceKit
import SessionSnodeKit
import SessionUtilitiesKit

public struct ClosedGroup: Codable, Identifiable, FetchableRecord, PersistableRecord, TableRecord, ColumnExpressible {
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
        case formationTimestamp
        
        case displayPictureUrl
        case displayPictureFilename
        case displayPictureEncryptionKey
        case lastDisplayPictureUpdate
        
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
    public let formationTimestamp: TimeInterval
    
    /// The URL from which to fetch the groups's display picture.
    public let displayPictureUrl: String?

    /// The file name of the groups's display picture on local storage.
    public let displayPictureFilename: String?

    /// The key with which the display picture is encrypted.
    public let displayPictureEncryptionKey: Data?
    
    /// The timestamp (in seconds since epoch) that the display picture was last updated
    public let lastDisplayPictureUpdate: TimeInterval?
    
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
        formationTimestamp: TimeInterval,
        displayPictureUrl: String? = nil,
        displayPictureFilename: String? = nil,
        displayPictureEncryptionKey: Data? = nil,
        lastDisplayPictureUpdate: TimeInterval? = nil,
        groupIdentityPrivateKey: Data? = nil,
        authData: Data? = nil,
        invited: Bool?
    ) {
        self.threadId = threadId
        self.name = name
        self.formationTimestamp = formationTimestamp
        self.displayPictureUrl = displayPictureUrl
        self.displayPictureFilename = displayPictureFilename
        self.displayPictureEncryptionKey = displayPictureEncryptionKey
        self.lastDisplayPictureUpdate = lastDisplayPictureUpdate
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
    
    /// The Group public key takes up 32 bytes
    static func pubKeyByteLength(for variant: SessionThread.Variant) -> Int {
        return 32
    }
    
    /// The Group secret key size differs between legacy and updated groups
    static func secretKeyByteLength(for variant: SessionThread.Variant) -> Int {
        switch variant {
            case .group: return 64
            default: return 32
        }
    }
    
    /// The Group authData size differs between legacy and updated groups
    static func authDataByteLength(for variant: SessionThread.Variant) -> Int {
        switch variant {
            case .group: return 100
            default: return 0
        }
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
        
        if group.invited == false {
            try ClosedGroup
                .filter(id: group.id)
                .updateAllAndConfig(
                    db,
                    ClosedGroup.Columns.invited.set(to: false),
                    calledFromConfig: calledFromConfigHandling,
                    using: dependencies
                )
        }
        
        try SessionUtil.createGroupState(
            groupSessionId: SessionId(.group, hex: group.id),
            userED25519KeyPair: userED25519KeyPair,
            groupIdentityPrivateKey: group.groupIdentityPrivateKey,
            authData: group.authData,
            using: dependencies
        )
        
        // Start polling
        dependencies[singleton: .closedGroupPoller].startIfNeeded(for: group.id, using: dependencies)
    }
    
    static func removeKeysAndUnsubscribe(
        _ db: Database? = nil,
        threadId: String,
        removeGroupData: Bool,
        calledFromConfigHandling: Bool
    ) throws {
        try removeKeysAndUnsubscribe(
            db,
            threadIds: [threadId],
            removeGroupData: removeGroupData,
            calledFromConfigHandling: calledFromConfigHandling
        )
    }
    
    static func removeKeysAndUnsubscribe(
        _ db: Database? = nil,
        threadIds: [String],
        removeGroupData: Bool,
        calledFromConfigHandling: Bool,
        using dependencies: Dependencies = Dependencies()
    ) throws {
        guard !threadIds.isEmpty else { return }
        guard let db: Database = db else {
            dependencies[singleton: .storage].write { db in
                try ClosedGroup.removeKeysAndUnsubscribe(
                    db,
                    threadIds: threadIds,
                    removeGroupData: removeGroupData,
                    calledFromConfigHandling: calledFromConfigHandling,
                    using: dependencies
                )
            }
            return
        }
        
        // Remove the group from the database and unsubscribe from PNs
        let userSessionId: SessionId = getUserSessionId(db, using: dependencies)
        
        threadIds.forEach { threadId in
            dependencies[singleton: .closedGroupPoller].stopPolling(for: threadId)
            
            try? PushNotificationAPI
                .preparedUnsubscribeFromLegacyGroup(
                    legacyGroupId: threadId,
                    userSessionId: userSessionId
                )
                .send(using: dependencies)
                .sinkUntilComplete()
        }
        
        // Remove the keys for the group
        try ClosedGroupKeyPair
            .filter(threadIds.contains(ClosedGroupKeyPair.Columns.threadId))
            .deleteAll(db)
        
        struct ThreadIdVariant: Decodable, FetchableRecord {
            let id: String
            let variant: SessionThread.Variant
        }
        
        let threadVariants: [ThreadIdVariant] = try SessionThread
            .select(.id, .variant)
            .filter(ids: threadIds)
            .asRequest(of: ThreadIdVariant.self)
            .fetchAll(db)
        
        // Remove the remaining group data if desired
        if removeGroupData {
            try SessionThread   // Intentionally use `deleteAll` here as this gets triggered via `deleteOrLeave`
                .filter(ids: threadIds)
                .deleteAll(db)
            
            try ClosedGroup
                .filter(ids: threadIds)
                .deleteAll(db)
            
            try GroupMember
                .filter(threadIds.contains(GroupMember.Columns.groupId))
                .deleteAll(db)
        }
        
        // If we weren't called from config handling then we need to remove the group
        // data from the config
        if !calledFromConfigHandling {
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
            
            // Remove the group config states
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
