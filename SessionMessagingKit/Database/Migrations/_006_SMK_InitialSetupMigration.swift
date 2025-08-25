// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import GRDB
import SessionUtilitiesKit

enum _006_SMK_InitialSetupMigration: Migration {
    static let identifier: String = "messagingKit.initialSetup"
    static let minExpectedRunDuration: TimeInterval = 0.1
    static let createdTables: [(TableRecord & FetchableRecord).Type] = [
        Contact.self, Profile.self, SessionThread.self, DisappearingMessagesConfiguration.self,
        ClosedGroup.self, OpenGroup.self, Capability.self, BlindedIdLookup.self,
        GroupMember.self, Interaction.self, Attachment.self, InteractionAttachment.self, Quote.self,
        LinkPreview.self, ThreadTypingIndicator.self
    ]
    
    public static let fullTextSearchTokenizer: FTS5TokenizerDescriptor = {
        // Define the tokenizer to be used in all the FTS tables
        // https://github.com/groue/GRDB.swift/blob/master/Documentation/FullTextSearch.md#fts5-tokenizers
        return .porter(wrapping: .unicode61())
    }()
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        try db.create(table: "contact") { t in
            t.column("id", .text)
                .notNull()
                .primaryKey()
            t.column("isTrusted", .boolean)
                .notNull()
                .defaults(to: false)
            t.column("isApproved", .boolean)
                .notNull()
                .defaults(to: false)
            t.column("isBlocked", .boolean)
                .notNull()
                .defaults(to: false)
            t.column("didApproveMe", .boolean)
                .notNull()
                .defaults(to: false)
            t.column("hasBeenBlocked", .boolean)
                .notNull()
                .defaults(to: false)
        }
        
        try db.create(table: "profile") { t in
            t.column("id", .text)
                .notNull()
                .primaryKey()
            t.column("name", .text).notNull()
            t.column("nickname", .text)
            t.column("profilePictureUrl", .text)
            t.column("profilePictureFileName", .text)
            t.column("profileEncryptionKey", .blob)
        }
        
        /// Create a full-text search table synchronized with the Profile table
        try db.create(virtualTable: "profile_fts", using: FTS5()) { t in
            t.synchronize(withTable: "profile")
            t.tokenizer = _006_SMK_InitialSetupMigration.fullTextSearchTokenizer
            
            t.column("nickname")
            t.column("name")
        }
        
        try db.create(table: "thread") { t in
            t.column("id", .text)
                .notNull()
                .primaryKey()
            t.column("variant", .integer).notNull()
            t.column("creationDateTimestamp", .double).notNull()
            t.column("shouldBeVisible", .boolean).notNull()
            t.column("isPinned", .boolean).notNull()
            t.column("messageDraft", .text)
            t.column("notificationSound", .integer)
            t.column("mutedUntilTimestamp", .double)
            t.column("onlyNotifyForMentions", .boolean)
                .notNull()
                .defaults(to: false)
        }
        
        try db.create(table: "disappearingMessagesConfiguration") { t in
            t.column("threadId", .text)
                .notNull()
                .primaryKey()
                .references("thread", onDelete: .cascade)             // Delete if Thread deleted
            t.column("isEnabled", .boolean)
                .defaults(to: false)
                .notNull()
            t.column("durationSeconds", .double)
                .defaults(to: 0)
                .notNull()
        }
        
        try db.create(table: "closedGroup") { t in
            t.column("threadId", .text)
                .notNull()
                .primaryKey()
                .references("thread", onDelete: .cascade)             // Delete if Thread deleted
            t.column("name", .text).notNull()
            t.column("formationTimestamp", .double).notNull()
        }
        
        /// Create a full-text search table synchronized with the ClosedGroup table
        try db.create(virtualTable: "closedGroup_fts", using: FTS5()) { t in
            t.synchronize(withTable: "closedGroup")
            t.tokenizer = _006_SMK_InitialSetupMigration.fullTextSearchTokenizer
            
            t.column("name")
        }
        
        try db.create(table: "closedGroupKeyPair") { t in
            t.column("threadId", .text)
                .notNull()
                .indexed()                                            // Quicker querying
                .references("closedGroup", onDelete: .cascade)        // Delete if ClosedGroup deleted
            t.column("publicKey", .blob).notNull()
            t.column("secretKey", .blob).notNull()
            t.column("receivedTimestamp", .double)
                .notNull()
                .indexed()                                            // Quicker querying
            
            t.uniqueKey(["publicKey", "secretKey", "receivedTimestamp"])
        }
        
        try db.create(table: "openGroup") { t in
            // Note: There is no foreign key constraint here because we need an OpenGroup entry to
            // exist to be able to retrieve the default open group rooms - as a result we need to
            // manually handle deletion of this object (in both OpenGroupManager and GarbageCollectionJob)
            t.column("threadId", .text)
                .notNull()
                .primaryKey()
            t.column("server", .text)
                .indexed()                                            // Quicker querying
                .notNull()
            t.column("roomToken", .text).notNull()
            t.column("publicKey", .text).notNull()
            t.column("isActive", .boolean)
                .notNull()
                .defaults(to: false)
            t.column("name", .text).notNull()
            t.column("description", .text)
            t.column("imageId", .text)
            t.column("imageData", .blob)
            t.column("userCount", .integer).notNull()
            t.column("infoUpdates", .integer).notNull()
            t.column("sequenceNumber", .integer).notNull()
            t.column("inboxLatestMessageId", .integer).notNull()
            t.column("outboxLatestMessageId", .integer).notNull()
            t.column("pollFailureCount", .integer)
                .notNull()
                .defaults(to: 0)
        }
        
        /// Create a full-text search table synchronized with the OpenGroup table
        try db.create(virtualTable: "openGroup_fts", using: FTS5()) { t in
            t.synchronize(withTable: "openGroup")
            t.tokenizer = _006_SMK_InitialSetupMigration.fullTextSearchTokenizer
            
            t.column("name")
        }
        
        try db.create(table: "capability") { t in
            t.column("openGroupServer", .text)
                .notNull()
                .indexed()                                            // Quicker querying
            t.column("variant", .text).notNull()
            t.column("isMissing", .boolean).notNull()
            
            t.primaryKey(["openGroupServer", "variant"])
        }
        
        try db.create(table: "blindedIdLookup") { t in
            t.column("blindedId", .text)
                .primaryKey()
            t.column("sessionId", .text)
                .indexed()                                            // Quicker querying
            t.column("openGroupServer", .text)
                .notNull()
                .indexed()                                            // Quicker querying
            t.column("openGroupPublicKey", .text)
                .notNull()
        }
        
        try db.create(table: "groupMember") { t in
            // Note: Since we don't know whether this will be stored against a 'ClosedGroup' or
            // an 'OpenGroup' we add the foreign key constraint against the thread itself (which
            // shares the same 'id' as the 'groupId') so we can cascade delete automatically
            t.column("groupId", .text)
                .notNull()
                .indexed()                                            // Quicker querying
                .references("thread", onDelete: .cascade)             // Delete if Thread deleted
            t.column("profileId", .text)
                .notNull()
                .indexed()                                            // Quicker querying
            t.column("role", .integer).notNull()
        }
        
        try db.create(table: "interaction") { t in
            t.column("id", .integer)
                .notNull()
                .primaryKey(autoincrement: true)
            t.column("serverHash", .text)
            t.column("messageUuid", .text)
                .indexed()                                            // Quicker querying
            t.column("threadId", .text)
                .notNull()
                .indexed()                                            // Quicker querying
                .references("thread", onDelete: .cascade)             // Delete if Thread deleted
            t.column("authorId", .text)
                .notNull()
                .indexed()                                            // Quicker querying
            
            t.column("variant", .integer).notNull()
            t.column("body", .text)
            t.column("timestampMs", .integer)
                .notNull()
                .indexed()                                            // Quicker querying
            t.column("receivedAtTimestampMs", .integer).notNull()
            t.column("wasRead", .boolean)
                .notNull()
                .indexed()                                            // Quicker querying
                .defaults(to: false)
            t.column("hasMention", .boolean)
                .notNull()
                .indexed()                                            // Quicker querying
                .defaults(to: false)
            t.column("expiresInSeconds", .double)
            t.column("expiresStartedAtMs", .double)
            t.column("linkPreviewUrl", .text)
            
            t.column("openGroupServerMessageId", .integer)
                .indexed()                                            // Quicker querying
            t.column("openGroupWhisperMods", .boolean)
                .notNull()
                .defaults(to: false)
            t.column("openGroupWhisperTo", .text)
            
            /// The below unique constraints are added to prevent messages being duplicated, we need
            /// multiple constraints to handle the different situations which can result in duplicate messages,
            /// the following describes the different cases where messages can be duplicated:
            ///
            /// Threads with variants: [`contact`, `closedGroup`]:
            ///   "Sync" messages (messages we resend to the current to ensure it appears on all linked devices):
            ///     `threadId`                    - Unique per thread
            ///     `authorId`                    - Unique per user
            ///     `timestampMs`              - Very low chance of collision (especially combined with other two)
            ///
            ///   Standard messages #1:
            ///     `threadId`                    - Unique per thread
            ///     `serverHash`                - Unique per message (deterministically generated)
            ///
            ///   Standard messages #1:
            ///     `threadId`                    - Unique per thread
            ///     `messageUuid`             - Very low chance of collision (especially combined with threadId)
            ///
            /// Threads with variants: [`openGroup`]:
            ///   `threadId`                                        - Unique per thread
            ///   `openGroupServerMessageId`     - Unique for VisibleMessage's on an OpenGroup server
            t.uniqueKey(["threadId", "authorId", "timestampMs"])
            t.uniqueKey(["threadId", "serverHash"])
            t.uniqueKey(["threadId", "messageUuid"])
            t.uniqueKey(["threadId", "openGroupServerMessageId"])
        }
        
        /// Create a full-text search table synchronized with the Interaction table
        try db.create(virtualTable: "interaction_fts", using: FTS5()) { t in
            t.synchronize(withTable: "interaction")
            t.tokenizer = _006_SMK_InitialSetupMigration.fullTextSearchTokenizer
            
            t.column("body")
        }
        
        try db.create(table: "recipientState") { t in
            t.column("interactionId", .integer)
                .notNull()
                .indexed()                                            // Quicker querying
                .references("interaction", onDelete: .cascade)        // Delete if interaction deleted
            t.column("recipientId", .text)
                .notNull()
                .indexed()                                            // Quicker querying
            t.column("state", .integer)
                .notNull()
                .indexed()                                            // Quicker querying
            t.column("readTimestampMs", .double)
            t.column("mostRecentFailureText", .text)
            
            // We want to ensure that a recipient can only have a single state for
            // each interaction
            t.primaryKey(["interactionId", "recipientId"])
        }
        
        try db.create(table: "attachment") { t in
            t.column("id", .text)
                .notNull()
                .primaryKey()
            t.column("serverId", .text)
            t.column("variant", .integer).notNull()
            t.column("state", .integer)
                .notNull()
                .indexed()                                            // Quicker querying
            t.column("contentType", .text).notNull()
            t.column("byteCount", .integer)
                .notNull()
                .defaults(to: 0)
            t.column("creationTimestamp", .double)
            t.column("sourceFilename", .text)
            t.column("downloadUrl", .text)
            t.column("localRelativeFilePath", .text)
            t.column("width", .integer)
            t.column("height", .integer)
            t.column("duration", .double)
            t.column("isVisualMedia", .boolean)
                .notNull()
                .defaults(to: false)
            t.column("isValid", .boolean)
                .notNull()
                .defaults(to: false)
            t.column("encryptionKey", .blob)
            t.column("digest", .blob)
            t.column("caption", .text)
        }
        
        try db.create(table: "interactionAttachment") { t in
            t.column("albumIndex", .integer).notNull()
            t.column("interactionId", .integer)
                .notNull()
                .indexed()                                            // Quicker querying
                .references("interaction", onDelete: .cascade)        // Delete if interaction deleted
            t.column("attachmentId", .text)
                .notNull()
                .indexed()                                            // Quicker querying
                .references("attachment", onDelete: .cascade)         // Delete if attachment deleted
        }
        
        try db.create(table: "quote") { t in
            t.column("interactionId", .integer)
                .notNull()
                .primaryKey()
                .references("interaction", onDelete: .cascade)        // Delete if interaction deleted
            t.column("authorId", .text)
                .notNull()
                .indexed()                                            // Quicker querying
                .references("profile")
            t.column("timestampMs", .double).notNull()
            t.column("body", .text)
            t.column("attachmentId", .text)
                .indexed()                                            // Quicker querying
                .references("attachment", onDelete: .setNull)         // Clear if attachment deleted
        }
        
        try db.create(table: "linkPreview") { t in
            t.column("url", .text)
                .notNull()
                .indexed()                                            // Quicker querying
            t.column("timestamp", .double)
                .notNull()
                .indexed()                                            // Quicker querying
            t.column("variant", .integer).notNull()
            t.column("title", .text)
            t.column("attachmentId", .text)
                .indexed()                                            // Quicker querying
                .references("attachment")                             // Managed via garbage collection
            
            t.primaryKey(["url", "timestamp"])
        }
        
        try db.create(table: "controlMessageProcessRecord") { t in
            t.column("threadId", .text)
                .notNull()
                .indexed()                                            // Quicker querying
            t.column("variant", .integer).notNull()
            t.column("timestampMs", .integer).notNull()
            t.column("serverExpirationTimestamp", .double)
            
            t.uniqueKey(["threadId", "variant", "timestampMs"])
        }
        
        try db.create(table: "threadTypingIndicator") { t in
            t.column("threadId", .text)
                .primaryKey()
                .references("thread", onDelete: .cascade)             // Delete if thread deleted
            t.column("timestampMs", .integer).notNull()
        }
        
        MigrationExecution.updateProgress(1)
    }
}
