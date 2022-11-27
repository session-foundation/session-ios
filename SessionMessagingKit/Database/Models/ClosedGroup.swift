// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import DifferenceKit
import SessionUtilitiesKit

public struct ClosedGroup: Codable, Identifiable, FetchableRecord, PersistableRecord, TableRecord, ColumnExpressible {
    public static var databaseTableName: String { "closedGroup" }
    internal static let threadForeignKey = ForeignKey([Columns.threadId], to: [SessionThread.Columns.id])
    private static let thread = belongsTo(SessionThread.self, using: threadForeignKey)
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
    }
    
    public var id: String { threadId }  // Identifiable
    public var publicKey: String { threadId }

    /// The id for the thread this closed group belongs to
    ///
    /// **Note:** This value will always be publicKey for the closed group
    public let threadId: String
    public let name: String
    public let formationTimestamp: TimeInterval
    
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
        formationTimestamp: TimeInterval
    ) {
        self.threadId = threadId
        self.name = name
        self.formationTimestamp = formationTimestamp
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

// MARK: - Convenience

public extension ClosedGroup {
    func asProfile() -> Profile {
        return Profile(
            id: threadId,
            name: name,
            profilePictureUrl: groupImageUrl,
            profilePictureFileName: groupImageFileName,
            profileEncryptionKey: groupImageEncryptionKey
        )
    }
    
    static func removeKeysAndUnsubscribe(
        _ db: Database? = nil,
        threadId: String,
        removeGroupData: Bool = false
    ) throws {
        try removeKeysAndUnsubscribe(db, threadIds: [threadId], removeGroupData: removeGroupData)
    }
    
    static func removeKeysAndUnsubscribe(
        _ db: Database? = nil,
        threadIds: [String],
        removeGroupData: Bool = false
    ) throws {
        guard let db: Database = db else {
            Storage.shared.write { db in
                try ClosedGroup.removeKeysAndUnsubscribe(
                    db,
                    threadIds: threadIds,
                    removeGroupData: removeGroupData)
            }
            return
        }
        
        // Remove the group from the database and unsubscribe from PNs
        let userPublicKey: String = getUserHexEncodedPublicKey(db)
        
        threadIds.forEach { threadId in
            ClosedGroupPoller.shared.stopPolling(for: threadId)
            
            PushNotificationAPI
                .performOperation(
                    .unsubscribe,
                    for: threadId,
                    publicKey: userPublicKey
                )
                .sinkUntilComplete()
        }
        
        // Remove the keys for the group
        try ClosedGroupKeyPair
            .filter(threadIds.contains(ClosedGroupKeyPair.Columns.threadId))
            .deleteAll(db)
        
        // Remove the remaining group data if desired
        if removeGroupData {
            try SessionThread
                .filter(ids: threadIds)
                .deleteAll(db)
            
            try ClosedGroup
                .filter(ids: threadIds)
                .deleteAll(db)
            
            try GroupMember
                .filter(threadIds.contains(GroupMember.Columns.groupId))
                .deleteAll(db)
        }
    }
}
