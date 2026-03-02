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
                using: dependencies
            )
            
            /// We need additional dedupe logic if the message is a `CallMessage` as multiple messages can related to the same call
            try ensureCallMessageIsNotADuplicate(
                threadId: threadId,
                callMessage: message as? CallMessage,
                using: dependencies
            )
        }
        
        /// Add `(Network.StorageServer.Message.serverClockToleranceMs * 2)` to `expirationTimestampSeconds`
        /// in order to try to ensure that our deduplication record outlasts the message lifetime on the storage server
        let finalExpiryTimestampSeconds: Int64? = serverExpirationTimestamp
            .map { Int64($0) + ((Network.StorageServer.Message.serverClockToleranceMs * 2) / 1000) }
        
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
        
        /// Insert & create special call-specific dedupe records
        try insertCallDedupeRecordsIfNeeded(
            db,
            threadId: threadId,
            callMessage: message as? CallMessage,
            expirationTimestampSeconds: finalExpiryTimestampSeconds,
            shouldDeleteWhenDeletingThread: shouldDeleteWhenDeletingThread,
            using: dependencies
        )
        
        /// Register dedupe files to be written
        dependencies[singleton: .messageDeduplicationBatchFileWriter].addPendingWrite(
            threadId: threadId,
            uniqueIdentifier: uniqueIdentifier,
            callMessage: message as? CallMessage
        )
        
        db.afterCommit(dedupeId: BatchFileWriter.dedupeId) {
            Task(priority: .utility) {
                await dependencies[singleton: .messageDeduplicationBatchFileWriter].processPendingWrites()
            }
        }
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
            try? await storage.writeAsync { db in
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
        using dependencies: Dependencies
    ) throws {
        try dependencies[singleton: .extensionHelper].createDedupeRecord(
            threadId: threadId,
            uniqueIdentifier: uniqueIdentifier
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
            using: dependencies
        )
    }
    
    static func ensureMessageIsNotADuplicate(
        threadId: String,
        uniqueIdentifier: String,
        using dependencies: Dependencies
    ) throws {
        if dependencies[singleton: .extensionHelper].dedupeRecordExists(
            threadId: threadId,
            uniqueIdentifier: uniqueIdentifier
        ) {
            throw MessageError.duplicateMessage
        }
    }
}

// MARK: - CallMessage Convenience

public extension MessageDeduplication {
    private static func insertCallDedupeRecordsIfNeeded(
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
        catch { throw MessageError.duplicatedCall }
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
            case .config: return
            case .standard(_, let threadVariant, let messageInfo, _):
                try insert(
                    db,
                    threadId: processedMessage.threadId,
                    threadVariant: threadVariant,
                    uniqueIdentifier: processedMessage.uniqueIdentifier,
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
            case .config: return
            case .standard:
                try createDedupeFile(
                    threadId: processedMessage.threadId,
                    uniqueIdentifier: processedMessage.uniqueIdentifier,
                    using: dependencies
                )
        }
    }
}

public extension CallMessage {
    var preOfferDedupeIdentifier: String { "\(uuid)-preOffer" }
}

// MARK: - MessageDeduplication BatchFileWriter

private extension MessageDeduplication {
    private struct PendingWrite {
        let threadId: String
        let uniqueIdentifier: String
        let callMessage: CallMessage?
    }
    
    actor BatchFileWriter: MessageDeduplicationBatchFileWriterType {
        fileprivate static let dedupeId: String = "BatchFileWriteDedupeId"
        
        private let dependencies: Dependencies
        nonisolated private let syncState: BatchFileWriterSyncState = BatchFileWriterSyncState()
        
        // MARK: - Initialiation
        
        init(using dependencies: Dependencies) {
            self.dependencies = dependencies
        }
        
        // MARK: - Functions
        
        nonisolated public func addPendingWrite(
            threadId: String,
            uniqueIdentifier: String,
            callMessage: CallMessage?
        ) {
            syncState.addPendingWrite(
                PendingWrite(
                    threadId: threadId,
                    uniqueIdentifier: uniqueIdentifier,
                    callMessage: callMessage
                )
            )
        }
        
        public func processPendingWrites() async {
            let pendingWrites: [PendingWrite] = syncState.popAll()
            
            for pendingWrite in pendingWrites {
                do {
                    /// Create the replicated file in the 'AppGroup' so that the PN extension is able to dedupe messages
                    try MessageDeduplication.createDedupeFile(
                        threadId: pendingWrite.threadId,
                        uniqueIdentifier: pendingWrite.uniqueIdentifier,
                        using: dependencies
                    )
                    
                    /// Create the replicated file in the 'AppGroup' so that the PN extension is able to dedupe call messages
                    try createCallDedupeFilesIfNeeded(
                        threadId: pendingWrite.threadId,
                        callMessage: pendingWrite.callMessage,
                        using: dependencies
                    )
                }
                catch {
                    Log.warn(.cat, "Failed to write dedupe file for \(pendingWrite.threadId) due to error: \(error).")
                }
            }
            
        }
    }
    
    private final class BatchFileWriterSyncState {
        private let lock: NSLock = NSLock()
        private var _pendingWrites: [PendingWrite] = []
        
        fileprivate func addPendingWrite(_ pendingWrite: PendingWrite) {
            lock.withLock { _pendingWrites.append(pendingWrite) }
        }
        
        fileprivate func popAll() -> [PendingWrite] {
            return lock.withLock {
                let result: [PendingWrite] = _pendingWrites
                _pendingWrites = []
                return result
            }
        }
    }
}

public extension Singleton {
    static let messageDeduplicationBatchFileWriter: SingletonConfig<MessageDeduplicationBatchFileWriterType> = Dependencies.create(
        identifier: "messageDeduplicationBatchFileWriter",
        createInstance: { dependencies, _ in MessageDeduplication.BatchFileWriter(using: dependencies) }
    )
}

// MARK: - MessageDeduplicationBatchFileWriterType

public protocol MessageDeduplicationBatchFileWriterType: Actor {
    nonisolated func addPendingWrite(
        threadId: String,
        uniqueIdentifier: String,
        callMessage: CallMessage?
    )
    func processPendingWrites() async
}
