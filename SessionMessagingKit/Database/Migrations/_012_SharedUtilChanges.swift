// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit

/// This migration recreates the interaction FTS table and adds the threadId so we can do a performant in-conversation
/// searh (currently it's much slower than the global search)
enum _012_SharedUtilChanges: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "SharedUtilChanges"
    static let needsConfigSync: Bool = true
    static let minExpectedRunDuration: TimeInterval = 0.1
    
    static func migrate(_ db: Database) throws {
        // Add `markedAsUnread` to the thread table
        try db.alter(table: SessionThread.self) { t in
            t.add(.markedAsUnread, .boolean)
            t.add(.pinnedPriority, .integer)
        }
        
        // Add an index for the 'ClosedGroupKeyPair' so we can lookup existing keys
        try db.createIndex(
            on: ClosedGroupKeyPair.self,
            columns: [.threadId, .publicKey, .secretKey]
        )
        
        // New table for storing the latest config dump for each type
        try db.create(table: ConfigDump.self) { t in
            t.column(.variant, .text)
                .notNull()
            t.column(.publicKey, .text)
                .notNull()
                .indexed()
            t.column(.data, .blob)
                .notNull()
            
            t.primaryKey([.variant, .publicKey])
        }
        
        // Migrate the 'isPinned' value to 'pinnedPriority'
        try SessionThread
            .filter(SessionThread.Columns.isPinned == true)
            .updateAll(
                db,
                SessionThread.Columns.pinnedPriority.set(to: 1)
            )
        
        // If we don't have an ed25519 key then no need to create cached dump data
        let userPublicKey: String = getUserHexEncodedPublicKey(db)
        
        guard let secretKey: [UInt8] = Identity.fetchUserEd25519KeyPair(db)?.secretKey else {
            Storage.update(progress: 1, for: self, in: target) // In case this is the last migration
            return
        }
        
        // MARK: - Shared Data
        
        let allThreads: [String: SessionThread] = try SessionThread
            .fetchAll(db)
            .reduce(into: [:]) { result, next in result[next.id] = next }
        
        // MARK: - UserProfile Config Dump
        
        let userProfileConf: UnsafeMutablePointer<config_object>? = try SessionUtil.loadState(
            for: .userProfile,
            secretKey: secretKey,
            cachedData: nil
        )
        try SessionUtil.update(
            profile: Profile.fetchOrCreateCurrentUser(db),
            in: userProfileConf
        )
        
        if config_needs_dump(userProfileConf) {
            try SessionUtil
                .createDump(
                    conf: userProfileConf,
                    for: .userProfile,
                    publicKey: userPublicKey
                )?
                .save(db)
        }
        
        // MARK: - Contact Config Dump
        
        let contactsData: [ContactInfo] = try Contact
            .filter(
                Contact.Columns.isBlocked == true ||
                allThreads.keys.contains(Contact.Columns.id)
            )
            .including(optional: Contact.profile)
            .asRequest(of: ContactInfo.self)
            .fetchAll(db)
        
        let contactsConf: UnsafeMutablePointer<config_object>? = try SessionUtil.loadState(
            for: .contacts,
            secretKey: secretKey,
            cachedData: nil
        )
        try SessionUtil.upsert(
            contactData: contactsData
                .map { data in
                    SessionUtil.SyncedContactInfo(
                        id: data.contact.id,
                        contact: data.contact,
                        profile: data.profile,
                        priority: Int32(allThreads[data.contact.id]?.pinnedPriority ?? 0),
                        hidden: (allThreads[data.contact.id]?.shouldBeVisible == true)
                    )
                },
            in: contactsConf
        )
        
        if config_needs_dump(contactsConf) {
            try SessionUtil
                .createDump(
                    conf: contactsConf,
                    for: .contacts,
                    publicKey: userPublicKey
                )?
                .save(db)
        }
        
        // MARK: - ConvoInfoVolatile Config Dump
        
        let volatileThreadInfo: [SessionUtil.VolatileThreadInfo] = SessionUtil.VolatileThreadInfo.fetchAll(db)
        let convoInfoVolatileConf: UnsafeMutablePointer<config_object>? = try SessionUtil.loadState(
            for: .convoInfoVolatile,
            secretKey: secretKey,
            cachedData: nil
        )
        try SessionUtil.upsert(
            convoInfoVolatileChanges: volatileThreadInfo,
            in: convoInfoVolatileConf
        )
        
        if config_needs_dump(convoInfoVolatileConf) {
            try SessionUtil
                .createDump(
                    conf: convoInfoVolatileConf,
                    for: .convoInfoVolatile,
                    publicKey: userPublicKey
                )?
                .save(db)
        }
        
        // MARK: - UserGroups Config Dump
        
        let legacyGroupData: [SessionUtil.LegacyGroupInfo] = try SessionUtil.LegacyGroupInfo.fetchAll(db)
        let communityData: [SessionUtil.OpenGroupUrlInfo] = try SessionUtil.OpenGroupUrlInfo.fetchAll(db)
        
        let userGroupsConf: UnsafeMutablePointer<config_object>? = try SessionUtil.loadState(
            for: .userGroups,
            secretKey: secretKey,
            cachedData: nil
        )
        try SessionUtil.upsert(
            legacyGroups: legacyGroupData,
            in: userGroupsConf
        )
        try SessionUtil.upsert(
            communities: communityData
                .map { SessionUtil.CommunityInfo(urlInfo: $0) },
            in: userGroupsConf
        )
        
        if config_needs_dump(userGroupsConf) {
            try SessionUtil
                .createDump(
                    conf: userGroupsConf,
                    for: .userGroups,
                    publicKey: userPublicKey
                )?
                .save(db)
        }
        
        // MARK: - Threads
        
        try SessionUtil
            .updatingThreads(db, Array(allThreads.values))
        
        // MARK: - Syncing
        
        // Enqueue a config sync job to ensure the generated configs get synced
        db.afterNextTransactionNestedOnce(dedupeId: SessionUtil.syncDedupeId(userPublicKey)) { db in
            ConfigurationSyncJob.enqueue(db, publicKey: userPublicKey)
        }
        
        Storage.update(progress: 1, for: self, in: target) // In case this is the last migration
    }
    
    // MARK: Fetchable Types
    
    struct ContactInfo: FetchableRecord, Decodable, ColumnExpressible {
        typealias Columns = CodingKeys
        enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
            case contact
            case profile
        }
        
        let contact: Contact
        let profile: Profile?
    }
    
    struct GroupInfo: FetchableRecord, Decodable, ColumnExpressible {
        typealias Columns = CodingKeys
        enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
            case closedGroup
            case disappearingMessagesConfiguration
            case groupMembers
        }
        
        let closedGroup: ClosedGroup
        let disappearingMessagesConfiguration: DisappearingMessagesConfiguration?
        let groupMembers: [GroupMember]
    }
}
