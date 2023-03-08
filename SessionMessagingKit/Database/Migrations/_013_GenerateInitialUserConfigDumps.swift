// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit

/// This migration goes through the current state of the database and generates config dumps for the user config types
///
/// **Note:** This migration won't be run until the `useSharedUtilForUserConfig` feature flag is enabled
enum _013_GenerateInitialUserConfigDumps: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "GenerateInitialUserConfigDumps"
    static let needsConfigSync: Bool = true
    static let minExpectedRunDuration: TimeInterval = 0.1   // TODO: Need to test this
    
    static func migrate(_ db: Database) throws {
        // If we have no ed25519 key then there is no need to create cached dump data
        guard let secretKey: [UInt8] = Identity.fetchUserEd25519KeyPair(db)?.secretKey else { return }
        
        // Load the initial config state if needed
        let userPublicKey: String = getUserHexEncodedPublicKey(db)
        
        SessionUtil.loadState(db, userPublicKey: userPublicKey, ed25519SecretKey: secretKey)
        
        // Retrieve all threads (we are going to base the config dump data on the active
        // threads rather than anything else in the database)
        let allThreads: [String: SessionThread] = try SessionThread
            .fetchAll(db)
            .reduce(into: [:]) { result, next in result[next.id] = next }
        
        // MARK: - UserProfile Config Dump
        
        try SessionUtil
            .config(for: .userProfile, publicKey: userPublicKey)
            .mutate { conf in
                try SessionUtil.update(
                    profile: Profile.fetchOrCreateCurrentUser(db),
                    in: conf
                )
                
                if config_needs_dump(conf) {
                    try SessionUtil
                        .createDump(
                            conf: conf,
                            for: .userProfile,
                            publicKey: userPublicKey
                        )?
                        .save(db)
                }
            }
        
        // MARK: - Contact Config Dump
        
        try SessionUtil
            .config(for: .contacts, publicKey: userPublicKey)
            .mutate { conf in
                // Exclude community, group and outgoing blinded message requests
                let validContactIds: [String] = allThreads
                    .values
                    .filter { thread in
                        thread.variant == .contact &&
                        SessionId(from: thread.id)?.prefix == .standard
                    }
                    .map { $0.id }
                let contactsData: [ContactInfo] = try Contact
                    .filter(
                        Contact.Columns.isBlocked == true ||
                        validContactIds.contains(Contact.Columns.id)
                    )
                    .including(optional: Contact.profile)
                    .asRequest(of: ContactInfo.self)
                    .fetchAll(db)
                
                try SessionUtil.upsert(
                    contactData: contactsData
                        .map { data in
                            SessionUtil.SyncedContactInfo(
                                id: data.contact.id,
                                contact: data.contact,
                                profile: data.profile,
                                hidden: (allThreads[data.contact.id]?.shouldBeVisible == true),
                                priority: Int32(allThreads[data.contact.id]?.pinnedPriority ?? 0)
                            )
                        },
                    in: conf
                )
                
                if config_needs_dump(conf) {
                    try SessionUtil
                        .createDump(
                            conf: conf,
                            for: .contacts,
                            publicKey: userPublicKey
                        )?
                        .save(db)
                }
            }
        
        // MARK: - ConvoInfoVolatile Config Dump
        
        try SessionUtil
            .config(for: .convoInfoVolatile, publicKey: userPublicKey)
            .mutate { conf in
                let volatileThreadInfo: [SessionUtil.VolatileThreadInfo] = SessionUtil.VolatileThreadInfo
                    .fetchAll(db, ids: Array(allThreads.keys))
                
                try SessionUtil.upsert(
                    convoInfoVolatileChanges: volatileThreadInfo,
                    in: conf
                )
                
                if config_needs_dump(conf) {
                    try SessionUtil
                        .createDump(
                            conf: conf,
                            for: .convoInfoVolatile,
                            publicKey: userPublicKey
                        )?
                        .save(db)
                }
            }
        
        // MARK: - UserGroups Config Dump
        
        try SessionUtil
            .config(for: .userGroups, publicKey: userPublicKey)
            .mutate { conf in
                let legacyGroupData: [SessionUtil.LegacyGroupInfo] = try SessionUtil.LegacyGroupInfo.fetchAll(db)
                let communityData: [SessionUtil.OpenGroupUrlInfo] = try SessionUtil.OpenGroupUrlInfo
                    .fetchAll(db, ids: Array(allThreads.keys))
                
                try SessionUtil.upsert(
                    legacyGroups: legacyGroupData,
                    in: conf
                )
                try SessionUtil.upsert(
                    communities: communityData
                        .map { urlInfo in
                            SessionUtil.CommunityInfo(
                                urlInfo: urlInfo,
                                priority: Int32(allThreads[urlInfo.threadId]?.pinnedPriority ?? 0)
                            )
                        },
                    in: conf
                )
                
                if config_needs_dump(conf) {
                    try SessionUtil
                        .createDump(
                            conf: conf,
                            for: .userGroups,
                            publicKey: userPublicKey
                        )?
                        .save(db)
                }
        }
                
        // MARK: - Threads
        
        try SessionUtil.updatingThreads(db, Array(allThreads.values))
        
        // MARK: - Syncing
        
        // Enqueue a config sync job to ensure the generated configs get synced
        db.afterNextTransactionNestedOnce(dedupeId: SessionUtil.syncDedupeId(userPublicKey)) { db in
            ConfigurationSyncJob.enqueue(db, publicKey: userPublicKey)
        }
        
        Storage.update(progress: 1, for: self, in: target) // In case this is the last migration
    }
    
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
