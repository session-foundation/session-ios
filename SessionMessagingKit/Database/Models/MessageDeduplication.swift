// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit
import SessionNetworkingKit

// MARK: - Log.Category

private extension Log.Category {
    static let cat: Log.Category = .create("MessageDeduplication", defaultLevel: .info)
}

// MARK: - MessageDeduplication

public struct MessageDeduplication: Codable, FetchableRecord, PersistableRecord, TableRecord, ColumnExpressible {
    public static var databaseTableName: String { "messageDeduplication" }
    
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case threadId
        case uniqueIdentifier
        case expirationTimestampSeconds
        case shouldDeleteWhenDeletingThread
    }
    
    public let threadId: String
    public let uniqueIdentifier: String
    public let expirationTimestampSeconds: Int64?
    public let shouldDeleteWhenDeletingThread: Bool
}

// MARK: - Convenience

public extension MessageDeduplication {
    static func insert(
        _ db: ObservingDatabase,
        threadId: String,
        threadVariant: SessionThread.Variant?,
        uniqueIdentifier: String?,
        legacyIdentifier: String? = nil,
        message: Message?,
        serverExpirationTimestamp: TimeInterval?,
        ignoreDedupeFiles: Bool,
        using dependencies: Dependencies
    ) throws {
        /// If we don't have a `uniqueIdentifier` then we can't dedupe the message
        guard let uniqueIdentifier: String = uniqueIdentifier else { return }
        
        /// If we aren't ignoring dedupe files then check to ensure they don't already exist (ie. a message was received as a push
        /// notification but doesn't yet exist in the database)
        if !ignoreDedupeFiles {
            /// Ensure this isn't a duplicate message received as a PN first
            try ensureMessageIsNotADuplicate(
                threadId: threadId,
                uniqueIdentifier: uniqueIdentifier,
                legacyIdentifier: legacyIdentifier,
                using: dependencies
            )
            
            /// We need additional dedupe logic if the message is a `CallMessage` as multiple messages can related to the same call
            try ensureCallMessageIsNotADuplicate(
                threadId: threadId,
                callMessage: message as? CallMessage,
                using: dependencies
            )
        }
        
        /// Add `(SnodeReceivedMessage.serverClockToleranceMs * 2)` to `expirationTimestampSeconds`
        /// in order to try to ensure that our deduplication record outlasts the message lifetime on the storage server
        let finalExpiryTimestampSeconds: Int64? = serverExpirationTimestamp
            .map { Int64($0) + ((SnodeReceivedMessage.serverClockToleranceMs * 2) / 1000) }
        
        /// When we delete a `contact` conversation we want to keep the dedupe records around because, if we don't, the
        /// conversation will just reappear (this isn't an issue for `legacyGroup` conversations because they no longer poll)
        ///
        /// For `community` conversations we only poll while the conversation exists and have a `seqNo` to poll from in order
        /// to prevent retrieving old messages
        ///
        /// Updated `group` conversations are a bit special because we want to delete _most_ records, but there are a few that
        /// can cause issues if we process them again so we hold on to those just in case
        let shouldDeleteWhenDeletingThread: Bool = {
            switch (threadVariant, message.map { Message.Variant(from: $0) }) {
                case (.contact, _): return false
                case (.community, _), (.legacyGroup, _): return true
                case (.group, .groupUpdateInvite), (.group, .groupUpdatePromote),
                    (.group, .groupUpdateMemberLeft), (.group, .groupUpdateInviteResponse):
                    return false
                case (.group, _): return true
                case (.none, .none), (.none, _): return false
            }
        }()
        
        /// Insert the `MessageDeduplication` record
        _ = try MessageDeduplication(
            threadId: threadId,
            uniqueIdentifier: uniqueIdentifier,
            expirationTimestampSeconds: finalExpiryTimestampSeconds,
            shouldDeleteWhenDeletingThread: shouldDeleteWhenDeletingThread
        ).insert(db)
        
        /// Create the replicated file in the 'AppGroup' so that the PN extension is able to dedupe messages
        try createDedupeFile(
            threadId: threadId,
            uniqueIdentifier: uniqueIdentifier,
            legacyIdentifier: legacyIdentifier,
            using: dependencies
        )
        
        /// Insert & create special call-specific dedupe records
        try insertCallDedupeRecordsIfNeeded(
            db,
            threadId: threadId,
            callMessage: message as? CallMessage,
            expirationTimestampSeconds: finalExpiryTimestampSeconds,
            shouldDeleteWhenDeletingThread: shouldDeleteWhenDeletingThread,
            using: dependencies
        )
        
        /// Create a legacy dedupe record
        try createLegacyDeduplicationRecord(
            db,
            threadId: threadId,
            legacyIdentifier: legacyIdentifier,
            legacyVariant: getLegacyVariant(for: message.map { Message.Variant(from: $0) }),
            timestampMs: message?.sentTimestampMs.map { Int64($0) },
            serverExpirationTimestamp: serverExpirationTimestamp,
            using: dependencies
        )
    }
    
    static func deleteIfNeeded(
        _ db: ObservingDatabase,
        threadIds: [String],
        using dependencies: Dependencies
    ) throws {
        /// First update the rows to be considered expired (so they are garbage collected in case the file deletion fails for some reason)
        try MessageDeduplication
            .filter(threadIds.contains(MessageDeduplication.Columns.threadId))
            .filter(MessageDeduplication.Columns.shouldDeleteWhenDeletingThread == true)
            .updateAll(
                db,
                MessageDeduplication.Columns.expirationTimestampSeconds.set(to: 0)
            )
        
        /// Then fetch the records and delete them from the database
        let records: [MessageDeduplication] = try MessageDeduplication
            .filter(threadIds.contains(MessageDeduplication.Columns.threadId))
            .filter(MessageDeduplication.Columns.shouldDeleteWhenDeletingThread == true)
            .fetchAll(db)
        
        /// Kick off a task to do file I/O (don't want to block the database waiting for file operations to complete)
        Task { [extensionHelper = dependencies[singleton: .extensionHelper], storage = dependencies[singleton: .storage]] in
            /// Upsert the "Last Cleared" record (we do this first just in case there are a lot of message to process and it takes a long time)
            threadIds.forEach { threadId in
                do { try extensionHelper.upsertLastClearedRecord(threadId: threadId) }
                catch { Log.warn(.cat, "Failed to update the last cleared record for \(threadId).") }
            }
            
            /// Remove any dedupe record files that should be removed
            var deletedRecords: [MessageDeduplication] = []
            
            records.forEach { record in
                do {
                    try extensionHelper.removeDedupeRecord(
                        threadId: record.threadId,
                        uniqueIdentifier: record.uniqueIdentifier
                    )
                    
                    deletedRecords.append(record)
                }
                catch { Log.warn(.cat, "Failed to delete dedupe file record (will rely on garbage collection).") }
            }
            
            /// Only delete the `MessageDeduplication` records that had their dedupe files successfully removed (if doing
            /// so fails then garbage collection will clean up the file and the record)
            storage.writeAsync { db in
                deletedRecords.forEach { record in
                    _ = try? MessageDeduplication
                        .filter(MessageDeduplication.Columns.threadId == record.threadId)
                        .filter(MessageDeduplication.Columns.uniqueIdentifier == record.uniqueIdentifier)
                        .deleteAll(db)
                }
            }
        }
    }
    
    static func createDedupeFile(
        threadId: String,
        uniqueIdentifier: String,
        legacyIdentifier: String? = nil,
        using dependencies: Dependencies
    ) throws {
        try dependencies[singleton: .extensionHelper].createDedupeRecord(
            threadId: threadId,
            uniqueIdentifier: uniqueIdentifier
        )
        
        /// Also create a dedupe file for the legacy identifier if provided
        guard let legacyIdentifier: String = legacyIdentifier else { return }
        
        try dependencies[singleton: .extensionHelper].createDedupeRecord(
            threadId: threadId,
            uniqueIdentifier: legacyIdentifier
        )
    }
    
    static func ensureMessageIsNotADuplicate(
        _ processedMessage: ProcessedMessage,
        using dependencies: Dependencies
    ) throws {
        typealias Variant = _040_MessageDeduplicationTable.ControlMessageProcessRecordVariant
        try ensureMessageIsNotADuplicate(
            threadId: processedMessage.threadId,
            uniqueIdentifier: processedMessage.uniqueIdentifier,
            legacyIdentifier: getLegacyIdentifier(for: processedMessage),
            using: dependencies
        )
    }
    
    static func ensureMessageIsNotADuplicate(
        threadId: String,
        uniqueIdentifier: String,
        legacyIdentifier: String? = nil,
        using dependencies: Dependencies
    ) throws {
        if dependencies[singleton: .extensionHelper].dedupeRecordExists(
            threadId: threadId,
            uniqueIdentifier: uniqueIdentifier
        ) {
            throw MessageReceiverError.duplicateMessage
        }
        
        /// Also check for a dedupe file using the legacy identifier
        guard let legacyIdentifier: String = legacyIdentifier else { return }
        
        if dependencies[singleton: .extensionHelper].dedupeRecordExists(
            threadId: threadId,
            uniqueIdentifier: legacyIdentifier
        ) {
            throw MessageReceiverError.duplicateMessage
        }
    }
}

// MARK: - CallMessage Convenience

public extension MessageDeduplication {
    static func insertCallDedupeRecordsIfNeeded(
        _ db: ObservingDatabase,
        threadId: String,
        callMessage: CallMessage?,
        expirationTimestampSeconds: Int64?,
        shouldDeleteWhenDeletingThread: Bool,
        using dependencies: Dependencies
    ) throws {
        guard let callMessage: CallMessage = callMessage else { return }
        
        switch (callMessage.kind, callMessage.state) {
            /// If the call was ended, was missed or had a permission issue then reject all subsequent messages associated with the call
            case (.endCall, _), (_, .missed), (_, .permissionDenied), (_, .permissionDeniedMicrophone):
                _ = try MessageDeduplication(
                    threadId: threadId,
                    uniqueIdentifier: callMessage.uuid,
                    expirationTimestampSeconds: expirationTimestampSeconds,
                    shouldDeleteWhenDeletingThread: shouldDeleteWhenDeletingThread
                ).insert(db)
                
            /// We only want to handle a single `preOffer` so add a custom record for that
            case (.preOffer, _):
                _ = try MessageDeduplication(
                    threadId: threadId,
                    uniqueIdentifier: callMessage.preOfferDedupeIdentifier,
                    expirationTimestampSeconds: expirationTimestampSeconds,
                    shouldDeleteWhenDeletingThread: shouldDeleteWhenDeletingThread
                ).insert(db)
            
            /// For any other combinations we don't want to deduplicate messages (as they are needed to keep the call going)
            default: break
        }
        
        /// Create the replicated file in the 'AppGroup' so that the PN extension is able to dedupe call messages
        try createCallDedupeFilesIfNeeded(
            threadId: threadId,
            callMessage: callMessage,
            using: dependencies
        )
    }
    
    static func createCallDedupeFilesIfNeeded(
        threadId: String,
        callMessage: CallMessage?,
        using dependencies: Dependencies
    ) throws {
        guard let callMessage: CallMessage = callMessage else { return }
        
        switch (callMessage.kind, callMessage.state) {
            /// If the call was ended, was missed or had a permission issue then reject all subsequent messages associated with the call
            case (.endCall, _), (_, .missed), (_, .permissionDenied), (_, .permissionDeniedMicrophone):
                try dependencies[singleton: .extensionHelper].createDedupeRecord(
                    threadId: threadId,
                    uniqueIdentifier: callMessage.uuid
                )
                
            /// We only want to handle a single `preOffer` so add a custom record for that
            case (.preOffer, _):
                try dependencies[singleton: .extensionHelper].createDedupeRecord(
                    threadId: threadId,
                    uniqueIdentifier: callMessage.preOfferDedupeIdentifier
                )
            
            /// For any other combinations we don't want to deduplicate messages (as they are needed to keep the call going)
            default: break
        }
    }
    
    static func ensureCallMessageIsNotADuplicate(
        threadId: String,
        callMessage: CallMessage?,
        using dependencies: Dependencies
    ) throws {
        guard let callMessage: CallMessage = callMessage else { return }
        
        do {
            /// We only want to handle the `preOffer` message once
            if callMessage.kind == .preOffer {
                try MessageDeduplication.ensureMessageIsNotADuplicate(
                    threadId: threadId,
                    uniqueIdentifier: callMessage.preOfferDedupeIdentifier,
                    using: dependencies
                )
            }
            
            /// If a call has officially "ended" then we don't want to handle _any_ further messages related to it
            try MessageDeduplication.ensureMessageIsNotADuplicate(
                threadId: threadId,
                uniqueIdentifier: callMessage.uuid,
                using: dependencies
            )
        }
        catch { throw MessageReceiverError.duplicatedCall }
    }
}

// MARK: - ProcessedMessage Convenience

public extension MessageDeduplication {
    static func insert(
        _ db: ObservingDatabase,
        processedMessage: ProcessedMessage,
        ignoreDedupeFiles: Bool,
        using dependencies: Dependencies
    ) throws {
        /// We don't actually want to dedupe config messages as `libSession` will take care of that logic and if we do anything
        /// special then it could result in unexpected behaviours where config messages don't get merged correctly
        switch processedMessage {
            case .config, .invalid: return
            case .standard(_, let threadVariant, _, let messageInfo, _):
                try insert(
                    db,
                    threadId: processedMessage.threadId,
                    threadVariant: threadVariant,
                    uniqueIdentifier: processedMessage.uniqueIdentifier,
                    legacyIdentifier: getLegacyIdentifier(for: processedMessage),
                    message: messageInfo.message,
                    serverExpirationTimestamp: messageInfo.serverExpirationTimestamp,
                    ignoreDedupeFiles: ignoreDedupeFiles,
                    using: dependencies
                )
        }
    }
    
    static func createDedupeFile(
        _ processedMessage: ProcessedMessage,
        using dependencies: Dependencies
    ) throws {
        /// We don't actually want to dedupe config messages as `libSession` will take care of that logic and if we do anything
        /// special then it could result in unexpected behaviours where config messages don't get merged correctly
        switch processedMessage {
            case .config, .invalid: return
            case .standard:
                try createDedupeFile(
                    threadId: processedMessage.threadId,
                    uniqueIdentifier: processedMessage.uniqueIdentifier,
                    legacyIdentifier: getLegacyIdentifier(for: processedMessage),
                    using: dependencies
                )
        }
    }
}

// MARK: - Legacy Dedupe Records

public extension MessageDeduplication {
    @available(*, deprecated, message: "⚠️ Remove this code once once enough time has passed since it's release (at least 1 month)")
    static let doesCreateLegacyRecords: Bool = true
}

private extension MessageDeduplication {
    @available(*, deprecated, message: "⚠️ Remove this code once once enough time has passed since it's release (at least 1 month)")
    private static func createLegacyDeduplicationRecord(
        _ db: ObservingDatabase,
        threadId: String,
        legacyIdentifier: String?,
        legacyVariant: _040_MessageDeduplicationTable.ControlMessageProcessRecordVariant?,
        timestampMs: Int64?,
        serverExpirationTimestamp: TimeInterval?,
        using dependencies: Dependencies
    ) throws {
        typealias Variant = _040_MessageDeduplicationTable.ControlMessageProcessRecordVariant
        guard
            let legacyIdentifier: String = legacyIdentifier,
            let legacyVariant: Variant = legacyVariant,
            let timestampMs: Int64 = timestampMs
        else { return }
        
        let expirationTimestampSeconds: Int64? = {
            /// If we have a server expiration for the hash then we should use that value as the priority
            if let serverExpirationTimestamp: TimeInterval = serverExpirationTimestamp {
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
        
        /// When we delete a `contact` conversation we want to keep the dedupe records around because, if we don't, the
        /// conversation will just reappear (this isn't an issue for `legacyGroup` conversations because they no longer poll)
        ///
        /// For `community` conversations we only poll while the conversation exists and have a `seqNo` to poll from in order
        /// to prevent retrieving old messages
        ///
        /// Updated `group` conversations are a bit special because we want to delete _most_ records, but there are a few that
        /// can cause issues if we process them again so we hold on to those just in case
        let shouldDeleteWhenDeletingThread: Bool = {
            switch legacyVariant {
                case .groupUpdateInvite, .groupUpdatePromote, .groupUpdateMemberLeft,
                    .groupUpdateInviteResponse:
                    return false
                default: return true
            }
        }()
        
        /// Add the record
        _ = try MessageDeduplication(
            threadId: threadId,
            uniqueIdentifier: legacyIdentifier,
            expirationTimestampSeconds: finalExpiryTimestampSeconds,
            shouldDeleteWhenDeletingThread: shouldDeleteWhenDeletingThread
        ).insert(db)
    }
    
    @available(*, deprecated, message: "⚠️ Remove this code once once enough time has passed since it's release (at least 1 month)")
    static func getLegacyVariant(for variant: Message.Variant?) -> _040_MessageDeduplicationTable.ControlMessageProcessRecordVariant? {
        guard let variant: Message.Variant = variant else { return nil }
        
        switch variant {
            case .visibleMessage: return .visibleMessageDedupe
            case .readReceipt: return .readReceipt
            case .typingIndicator: return .typingIndicator
            case .unsendRequest: return .unsendRequest
            case .dataExtractionNotification: return .dataExtractionNotification
            case .expirationTimerUpdate: return .expirationTimerUpdate
            case .messageRequestResponse: return .messageRequestResponse
            case .callMessage: return .call
            case .groupUpdateInvite, .groupUpdateMemberChange, .groupUpdatePromote:
                return .groupUpdateMemberChange
            case .groupUpdateInfoChange: return .groupUpdateInfoChange
            case .groupUpdateMemberLeft: return .groupUpdateMemberLeft
            case .groupUpdateMemberLeftNotification: return .groupUpdateMemberLeftNotification
            case .groupUpdateInviteResponse: return .groupUpdateInviteResponse
            case .groupUpdateDeleteMemberContent: return .groupUpdateDeleteMemberContent
                
            case .libSessionMessage: return nil
        }
    }
        
    @available(*, deprecated, message: "⚠️ Remove this code once once enough time has passed since it's release (at least 1 month)")
    static func getLegacyIdentifier(for processedMessage: ProcessedMessage) -> String? {
        switch processedMessage {
            case .config, .invalid: return nil
            case .standard(_, _, _, let messageInfo, _):
                guard
                    let timestampMs: UInt64 = messageInfo.message.sentTimestampMs,
                    let variant: _040_MessageDeduplicationTable.ControlMessageProcessRecordVariant = getLegacyVariant(for: Message.Variant(from: messageInfo.message))
                else { return nil }
                
                return "LegacyRecord-\(variant.rawValue)-\(timestampMs)" // stringlint:ignore
        }
    }
}

public extension CallMessage {
    var preOfferDedupeIdentifier: String { "\(uuid)-preOffer" }
}

