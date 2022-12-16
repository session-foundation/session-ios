// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit

/// This migration recreates the interaction FTS table and adds the threadId so we can do a performant in-conversation
/// searh (currently it's much slower than the global search)
enum _011_SharedUtilChanges: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "SharedUtilChanges"
    static let needsConfigSync: Bool = true
    static let minExpectedRunDuration: TimeInterval = 0.1
    
    static func migrate(_ db: Database) throws {
        try db.create(table: ConfigDump.self) { t in
            t.column(.variant, .text)
                .notNull()
            t.column(.publicKey, .text)
                .notNull()
                .indexed()
            t.column(.data, .blob)
                .notNull()
            t.column(.combinedMessageHashes, .text)
            
            t.primaryKey([.variant, .publicKey])
        }
        
        // If we don't have an ed25519 key then no need to create cached dump data
        let userPublicKey: String = getUserHexEncodedPublicKey(db)
        
        guard let secretKey: [UInt8] = Identity.fetchUserEd25519KeyPair(db)?.secretKey else {
            Storage.update(progress: 1, for: self, in: target) // In case this is the last migration
            return
        }
        
        // Create a dump for the user profile data
        let userProfileConf: UnsafeMutablePointer<config_object>? = try SessionUtil.loadState(
            for: .userProfile,
            secretKey: secretKey,
            cachedData: nil
        )
        let userProfileConfResult: SessionUtil.ConfResult = try SessionUtil.update(
            profile: Profile.fetchOrCreateCurrentUser(db),
            in: Atomic(userProfileConf)
        )
        
        if userProfileConfResult.needsDump {
            try SessionUtil
                .createDump(
                    conf: userProfileConf,
                    for: .userProfile,
                    publicKey: userPublicKey,
                    messageHashes: nil
                )?
                .save(db)
        }
        
        // Create a dump for the contacts data
        struct ContactInfo: FetchableRecord, Decodable, ColumnExpressible {
            typealias Columns = CodingKeys
            enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
                case contact
                case profile
            }
            
            let contact: Contact
            let profile: Profile?
        }
        let contactsData: [ContactInfo] = try Contact
            .including(optional: Contact.profile)
            .asRequest(of: ContactInfo.self)
            .fetchAll(db)
        
        let contactsConf: UnsafeMutablePointer<config_object>? = try SessionUtil.loadState(
            for: .contacts,
            secretKey: secretKey,
            cachedData: nil
        )
        let contactsConfResult: SessionUtil.ConfResult = try SessionUtil.upsert(
            contactData: contactsData.map { ($0.contact.id, $0.contact, $0.profile) },
            in: Atomic(contactsConf)
        )
        
        if contactsConfResult.needsDump {
            try SessionUtil
                .createDump(
                    conf: contactsConf,
                    for: .contacts,
                    publicKey: userPublicKey,
                    messageHashes: nil
                )?
                .save(db)
        }
        
        Storage.update(progress: 1, for: self, in: target) // In case this is the last migration
    }
}
