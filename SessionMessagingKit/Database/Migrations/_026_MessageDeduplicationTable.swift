// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit
import SessionNetworkingKit

/// The different platforms use different approaches for message deduplication but in the future we want to shift the database logic into
/// `libSession` so it makes sense to try to define a longer-term deduplication approach we we can use in `libSession`, additonally
/// the PN extension will need to replicate this deduplication data so having a single source-of-truth for the data will make things easier
enum _026_MessageDeduplicationTable: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "MessageDeduplicationTable"
    static let minExpectedRunDuration: TimeInterval = 5
    static var createdTables: [(FetchableRecord & TableRecord).Type] = [
        MessageDeduplication.self
    ]
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        typealias DedupeRecord = (
            threadId: String,
            identifier: String,
            timestampMs: Int64,
            finalExpirationTimestampSeconds: Int64?,
            shouldDeleteWhenDeletingThread: Bool
        )
        
        /// Pre-calculate the required timestamps
        ///
        /// **oldestSnodeTimestampMs:** Messages on a snode expire after ~14 days so exclude older messages
        /// **oldestNotificationDedupeTimestampMs:** We probably only need to create "dedupe" records for the PN extension
        /// for messages sent within the last ~60 mins (any older and the user probably wouldn't get a PN
        let timestampNowInSec: Int64 = Int64(dependencies.dateNow.timeIntervalSince1970)
        let oldestSnodeTimestampMs: Int64 = ((timestampNowInSec * 1000) - SnodeReceivedMessage.defaultExpirationMs)
        let oldestNotificationDedupeTimestampMs: Int64 = ((timestampNowInSec - (60 * 60)) * 1000)
        
        try db.create(table: "messageDeduplication") { t in
            t.column("threadId", .text)
                .notNull()
                .indexed()                                            // Quicker querying
            t.column("uniqueIdentifier", .text)
                .notNull()
                .indexed()                                            // Quicker querying
            t.column("expirationTimestampSeconds", .integer)
                .indexed()                                            // Quicker querying
            t.column("shouldDeleteWhenDeletingThread", .boolean)
                .notNull()
                .defaults(to: false)
            t.primaryKey(["threadId", "uniqueIdentifier"])
        }
        
        /// Pre-create the insertion SQL to avoid having to construct it in every iteration
        let insertSQL = """
            INSERT INTO messageDeduplication (threadId, uniqueIdentifier, expirationTimestampSeconds, shouldDeleteWhenDeletingThread)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(threadId, uniqueIdentifier) DO NOTHING
        """
        let insertStatement = try db.makeStatement(sql: insertSQL)
        
        /// Retrieve existing de-duplication information
        let threadInfo: [Row] = try Row.fetchAll(db, sql: """
            SELECT
                id AS threadId,
                variant AS threadVariant
            FROM thread
        """)
        let interactionInfo: [Row] = try Row.fetchAll(db, sql: """
            SELECT
                threadId,
                variant AS interactionVariant,
                timestampMs,
                serverHash,
                openGroupServerMessageId,
                expiresInSeconds,
                expiresStartedAtMs
            FROM interaction
            WHERE (
                timestampMs > \(oldestSnodeTimestampMs) OR NOT (
                    -- Quick way to include all community messages without joining the thread table
                    LENGTH(threadId) = 66 AND (
                        (threadId >= '03' AND threadId < '04') OR
                        (threadId >= '05' AND threadId < '06') OR
                        (threadId >= '15' AND threadId < '16') OR
                        (threadId >= '25' AND threadId < '26')
                    )
                )
            )
        """)
        let controlMessageProcessRecords: [Row] = try Row.fetchAll(db, sql: """
            SELECT
                threadId,
                variant,
                timestampMs,
                serverExpirationTimestamp
            FROM controlMessageProcessRecord
            WHERE (
                serverExpirationTimestamp IS NULL OR
                serverExpirationTimestamp > \(timestampNowInSec)
            )  
        """)
        
        /// Put the known hashes into a temporary table (if we got interactions with hashes
        var expirationByHash: [String: Int64] = [:]
        let allHashes: Set<String> = Set(interactionInfo.compactMap { row in row["serverHash"] })
        
        if !allHashes.isEmpty {
            try db.execute(sql: "CREATE TEMP TABLE tmpHashes (hash TEXT PRIMARY KEY NOT NULL)")
            let insertHashSQL = "INSERT OR IGNORE INTO tmpHashes (hash) VALUES (?)"
            let insertHashStatement = try db.makeStatement(sql: insertHashSQL)
            try allHashes.forEach { try insertHashStatement.execute(arguments: [$0]) }
            
            /// Query the `snodeReceivedMessageInfo` table to extract the expiration for only the know hashes
            let receivedMessageInfo: [Row] = try Row.fetchAll(db, sql: """
                SELECT
                    snodeReceivedMessageInfo.hash,
                    MIN(snodeReceivedMessageInfo.expirationDateMs) AS expirationDateMs
                FROM snodeReceivedMessageInfo
                JOIN tmpHashes ON tmpHashes.hash = snodeReceivedMessageInfo.hash  
                GROUP BY snodeReceivedMessageInfo.hash
            """)
            receivedMessageInfo.forEach { row in
                expirationByHash[row["hash"]] = row["expirationDateMs"]
            }
            try db.execute(sql: "DROP TABLE tmpHashes")
        }
        
        let threadVariants: [String: SessionThread.Variant] = threadInfo
            .reduce(into: [:]) { result, row in
                guard
                    let threadId: String = row["threadId"],
                    let rawThreadVariant: Int = row["threadVariant"],
                    let threadVariant: SessionThread.Variant = SessionThread.Variant(rawValue: rawThreadVariant)
                else { return }
                
                result[threadId] = threadVariant
            }
        
        /// Update the progress (from testing the above fetching took ~60% of the duration of the migration)
        MigrationExecution.updateProgress(0.6)
        
        var recordsToInsert: [DedupeRecord] = []
        var processedKeys: Set<String> = []
        
        /// Process interactions
        interactionInfo.forEach { row in
            guard
                let threadId: String = row["threadId"],
                let rawInteractionVariant: Int = row["interactionVariant"],
                let threadVariant: SessionThread.Variant = threadVariants[threadId],
                let interactionVariant: Interaction.Variant = Interaction.Variant(rawValue: rawInteractionVariant),
                let identifier: String = {
                    /// Messages stored on a snode should always have a `serverHash` value (aside from old control messages
                    /// which may not have because they were created locally and the hash wasn't attached during creation)
                    if let hash: String = row["serverHash"] { return hash }
                    
                    /// Outgoing blinded message requests are sent via a community so actually have a `openGroupServerMessageId`
                    /// instead of a `serverHash` even though they are considered `contact` conversations so we need to handle
                    /// both values to ensure we don't miss the deduplication record
                    if let id: Int64 = row["openGroupServerMessageId"] { return "\(id)" }
                    
                    /// Some control messages (and even buggy "proper" messages) could be inserted into the database without
                    /// either a `serverHash` or `openGroupServerMessageId` but still create a
                    /// `ControlMessageProcessRecord`, for those cases we want
                    if let variant: Int64 = row["variant"], let timestampMs: Int64 = row["timestampMs"] {
                        return "\(variant)-\(timestampMs)"
                    }
                    
                    /// If we have none of the above values then we can't dedupe this message at all
                    return nil
                }()
            else { return }
            
            let expirationTimestampSeconds: Int64? = {
                /// Messages in a community conversation don't expire
                guard threadVariant != .community else { return nil }
                
                /// If we have a server expiration for the hash then we should use that value as the priority
                if
                    let hash: String = row["serverHash"],
                    let expirationTimestampMs: Int64 = expirationByHash[hash]
                {
                    return (expirationTimestampMs / 1000)
                }
                
                /// If this is a disappearing message then fallback to using that value
                if
                    let expiresStartedAtMs: Int64 = row["expiresStartedAtMs"],
                    let expiresInSeconds: Int64 = row["expiresInSeconds"]
                {
                    return ((expiresStartedAtMs / 1000) + expiresInSeconds)
                }
                
                /// If we got here then it means we have no way to know when the message should expire but messages stored on
                /// a snode as well as outgoing blinded message reuqests stored on a SOGS both have a similar default expiration
                /// so create one manually by using `SnodeReceivedMessage.defaultExpirationMs`
                ///
                /// For a `contact` conversation at the time of writing this migration there _shouldn't_ be any type of message
                /// which never expires or has it's TTL extended (outside of config messages)
                ///
                /// If we have a `timestampMs` then base our custom expiration on that
                if let timestampMs: Int64 = row["timestampMs"] {
                    return ((timestampMs + SnodeReceivedMessage.defaultExpirationMs) / 1000)
                }
                
                /// Otherwise just use the current time if we somehow don't have a timestamp (this case shouldn't be possible)
                return (timestampNowInSec + (SnodeReceivedMessage.defaultExpirationMs / 1000))
            }()
            
            /// Add `(SnodeReceivedMessage.serverClockToleranceMs * 2)` to `expirationTimestampSeconds`
            /// in order to try to ensure that our deduplication record outlasts the message lifetime on the storage server
            let finalExpiryTimestampSeconds: Int64? = expirationTimestampSeconds
                .map { $0 + ((SnodeReceivedMessage.serverClockToleranceMs * 2) / 1000) }
            
            /// If this record would have already expired then there is no need to insert a record for it
            guard (finalExpiryTimestampSeconds ?? timestampNowInSec) < timestampNowInSec else { return }
            
            /// When we delete a `contact` conversation we want to keep the dedupe records around because, if we don't, the
            /// conversation will just reappear (this isn't an issue for `legacyGroup` conversations because they no longer poll)
            ///
            /// For `community` conversations we only poll while the conversation exists and have a `seqNo` to poll from in order
            /// to prevent retrieving old messages
            ///
            /// Updated `group` conversations are a bit special because we want to delete _most_ records, but there are a few that
            /// can cause issues if we process them again so we hold on to those just in case
            let shouldDeleteWhenDeletingThread: Bool = {
                switch threadVariant {
                    case .contact: return false
                    case .community, .legacyGroup: return true
                    case .group: return (interactionVariant != .infoGroupInfoInvited)
                }
            }()
            
            /// Add the record
            recordsToInsert.append((
                threadId,
                identifier,
                ((row["timestampMs"] as? Int64) ?? timestampNowInSec),
                finalExpiryTimestampSeconds,
                shouldDeleteWhenDeletingThread
            ))
            
            /// Store the legacy identifier if there would be one
            guard let timestampMs: Int64 = row["timestampMs"] else { return }
            
            processedKeys.insert("\(threadId):\(legacyDedupeIdentifier(variant: interactionVariant, timestampMs: timestampMs))")
        }
        
        /// Some control messages could be inserted into the database without either a `serverHash` or
        /// `openGroupServerMessageId` but still create a `ControlMessageProcessRecord` in which case we still want
        /// to dedupe the messages so we need to add these "legacy" deduplication records
        controlMessageProcessRecords.forEach { row in
            guard
                let threadId: String = row["threadId"],
                let threadVariant: SessionThread.Variant = threadVariants[threadId],
                let rawVariant: Int = row["variant"],
                let variant: ControlMessageProcessRecordVariant = ControlMessageProcessRecordVariant(rawValue: rawVariant),
                let timestampMs: Int64 = row["timestampMs"]
            else { return }
            
            /// Create a custom unique identifier for the legacy record (these will be deprecated and stop being added in a
            /// subsequent release
            let identifier: String = "LegacyRecord-\(rawVariant)-\(timestampMs)"
            
            guard !processedKeys.contains("\(threadId):\(identifier)") else { return }
            
            let expirationTimestampSeconds: Int64? = {
                /// Messages in a community conversation don't expire
                guard threadVariant != .community else { return nil }
                
                /// If we have a server expiration for the hash then we should use that value as the priority
                if let serverExpirationTimestamp: TimeInterval = row["serverExpirationTimestamp"] {
                    return Int64(serverExpirationTimestamp)
                }
                
                /// If we got here then it means we have no way to know when the message should expire but messages stored on
                /// a snode as well as outgoing blinded message reuqests stored on a SOGS both have a similar default expiration
                /// so create one manually by using `SnodeReceivedMessage.defaultExpirationMs`
                ///
                /// For a `contact` conversation at the time of writing this migration there _shouldn't_ be any type of message
                /// which never expires or has it's TTL extended (outside of config messages)
                ///
                /// If we have a `timestampMs` then base our custom expiration on that
                return ((timestampMs + SnodeReceivedMessage.defaultExpirationMs) / 1000)
            }()
            
            /// Add `(SnodeReceivedMessage.serverClockToleranceMs * 2)` to `expirationTimestampSeconds`
            /// in order to try to ensure that our deduplication record outlasts the message lifetime on the storage server
            let finalExpiryTimestampSeconds: Int64? = expirationTimestampSeconds
                .map { $0 + ((SnodeReceivedMessage.serverClockToleranceMs * 2) / 1000) }
            
            /// If this record would have already expired then there is no need to insert a record for it
            guard (finalExpiryTimestampSeconds ?? timestampNowInSec) < timestampNowInSec else { return }
            
            /// When we delete a `contact` conversation we want to keep the dedupe records around because, if we don't, the
            /// conversation will just reappear (this isn't an issue for `legacyGroup` conversations because they no longer poll)
            ///
            /// For `community` conversations we only poll while the conversation exists and have a `seqNo` to poll from in order
            /// to prevent retrieving old messages
            ///
            /// Updated `group` conversations are a bit special because we want to delete _most_ records, but there are a few that
            /// can cause issues if we process them again so we hold on to those just in case
            let shouldDeleteWhenDeletingThread: Bool = {
                switch variant {
                    case .groupUpdateInvite, .groupUpdatePromote, .groupUpdateMemberLeft,
                        .groupUpdateInviteResponse:
                        return false
                    default: return true
                }
            }()
            
            /// Add the record
            recordsToInsert.append((
                threadId,
                identifier,
                timestampMs,
                finalExpiryTimestampSeconds,
                shouldDeleteWhenDeletingThread
            ))
        }
        
        /// Insert all of the dedupe records
        try recordsToInsert.forEach { record in
            try insertStatement.execute(arguments: [
                record.threadId,
                record.identifier,
                record.finalExpirationTimestampSeconds,
                record.shouldDeleteWhenDeletingThread
            ])
            
            /// Create dedupe records for the PN extension
            if record.timestampMs > oldestNotificationDedupeTimestampMs {
                try dependencies[singleton: .extensionHelper].createDedupeRecord(
                    threadId: record.threadId,
                    uniqueIdentifier: record.identifier
                )
            }
        }
        
        /// Drop the old `controlMessageProcessRecord` table (since we no longer need it)
        try db.execute(sql: "DROP TABLE controlMessageProcessRecord")
        
        MigrationExecution.updateProgress(1)
    }
}

internal extension _026_MessageDeduplicationTable {
    static func legacyDedupeIdentifier(
        variant: Interaction.Variant,
        timestampMs: Int64
    ) -> String {
        let processRecordVariant: ControlMessageProcessRecordVariant = {
            switch variant {
                case .standardOutgoing, .standardIncoming, ._legacyStandardIncomingDeleted,
                    .standardIncomingDeleted, .standardIncomingDeletedLocally, .standardOutgoingDeleted,
                    .standardOutgoingDeletedLocally, .infoLegacyGroupCreated:
                    return .visibleMessageDedupe
                    
                case .infoLegacyGroupUpdated, .infoLegacyGroupCurrentUserLeft: return .legacyGroupControlMessage
                case .infoDisappearingMessagesUpdate: return .expirationTimerUpdate
                case .infoScreenshotNotification, .infoMediaSavedNotification: return .dataExtractionNotification
                case .infoMessageRequestAccepted: return .messageRequestResponse
                case .infoCall: return .call
                case .infoGroupInfoUpdated: return .groupUpdateInfoChange
                case .infoGroupInfoInvited, .infoGroupMembersUpdated: return .groupUpdateMemberChange
                    
                case .infoGroupCurrentUserLeaving, .infoGroupCurrentUserErrorLeaving:
                    return .groupUpdateMemberLeft
            }
        }()
        
        return "LegacyRecord-\(processRecordVariant.rawValue)-\(timestampMs)"
    }
}

internal extension _026_MessageDeduplicationTable {
    enum ControlMessageProcessRecordVariant: Int {
        case readReceipt = 1
        case typingIndicator = 2
        case legacyGroupControlMessage = 3
        case dataExtractionNotification = 4
        case expirationTimerUpdate = 5
        case unsendRequest = 7
        case messageRequestResponse = 8
        case call = 9
        case visibleMessageDedupe = 10
        case groupUpdateInvite = 11
        case groupUpdatePromote = 12
        case groupUpdateInfoChange = 13
        case groupUpdateMemberChange = 14
        case groupUpdateMemberLeft = 15
        case groupUpdateMemberLeftNotification = 16
        case groupUpdateInviteResponse = 17
        case groupUpdateDeleteMemberContent = 18
    }
}
