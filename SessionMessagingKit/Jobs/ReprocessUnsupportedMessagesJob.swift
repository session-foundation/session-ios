// Copyright © 2026 Session Technology Foundation. All rights reserved.
//
// stringlint:disable

import Foundation
import GRDB
import SessionNetworkingKit
import SessionUtilitiesKit

// MARK: - Log.Category

private extension Log.Category {
    static let cat: Log.Category = .create("ReprocessUnsupportedMessagesJob", defaultLevel: .info)
}

// MARK: - ReprocessUnsupportedMessagesJob

/// Runs on launch and replays any retained `UnsupportedMessageRecord` which hasn't been attempted by the current version, so
/// a message type added by an update replaces its placeholder in the same position
public enum ReprocessUnsupportedMessagesJob: JobExecutor {
    public static let maxFailureCount: Int = -1
    public static let requiresThreadId: Bool = false
    public static let requiresInteractionId: Bool = false

    public static func canRunConcurrentlyWith(
        runningJobs: [JobState],
        jobState: JobState,
        using dependencies: Dependencies
    ) -> Bool {
        return false
    }

    public static func run(_ job: Job, using dependencies: Dependencies) async throws -> JobExecutionResult {
        await dependencies.untilInitialised(cache: .general)

        guard dependencies[cache: .general].userExists else { return .success }

        let currentVersion: String = UnsupportedMessageRecord.currentVersion(using: dependencies)
        /// Failing to enforce the limits shouldn't prevent retained messages from being reprocessed
        do {
            try await dependencies[singleton: .storage].write { db in
                try UnsupportedMessageRecord.enforceLimits(db, using: dependencies)
            }
        }
        catch { Log.error(.cat, "Failed to enforce retained message limits due to error: \(error).") }

        /// No legacy version can decrypt a `newerFormat` message, so mark them as attempted without ever loading their data
        try await dependencies[singleton: .storage].write { db in
            try UnsupportedMessageRecord
                .filter(UnsupportedMessageRecord.Columns.kind == UnsupportedMessageRecord.Kind.newerFormat)
                .filter(UnsupportedMessageRecord.Columns.lastAttemptVersion != currentVersion)
                .updateAll(db, UnsupportedMessageRecord.Columns.lastAttemptVersion.set(to: currentVersion))
        }

        var attemptedCount: Int = 0
        var replacedCount: Int = 0
        var failedCount: Int = 0
        var lastRecordId: Int64 = 0

        while true {
            try Task.checkCancellation()

            let recordIds: [Int64] = try await dependencies[singleton: .storage].read { [lastRecordId] db in
                try UnsupportedMessageRecord
                    .select(.id)
                    .filter(UnsupportedMessageRecord.Columns.kind == UnsupportedMessageRecord.Kind.unknownType)
                    .filter(UnsupportedMessageRecord.Columns.lastAttemptVersion != currentVersion)
                    .filter(UnsupportedMessageRecord.Columns.id > lastRecordId)
                    .order(UnsupportedMessageRecord.Columns.id)
                    .limit(50)
                    .asRequest(of: Int64.self)
                    .fetchAll(db)
            }

            guard let pageLastRecordId: Int64 = recordIds.last else { break }

            for recordId in recordIds {
                try Task.checkCancellation()

                let result: ReprocessResult = try await dependencies[singleton: .storage].write { db in
                    try reprocess(db, recordId: recordId, currentVersion: currentVersion, using: dependencies)
                }

                switch result {
                    case .replaced: replacedCount += 1
                    case .failed: failedCount += 1
                    case .stillUnsupported, .missing: break
                }
            }

            attemptedCount += recordIds.count
            lastRecordId = pageLastRecordId
        }

        guard attemptedCount > 0 else { return .success }

        Log.info(.cat, "Reprocessed \(attemptedCount) retained message(s): \(replacedCount) replaced, \(failedCount) failed.")
        return .success
    }

    internal enum ReprocessResult {
        case replaced
        case stillUnsupported

        /// This version failed to process the message for some other reason, the record is kept for a later version to retry
        case failed

        /// The record was removed before it could be reprocessed
        case missing
    }

    internal static func reprocess(
        _ db: ObservingDatabase,
        recordId: Int64,
        currentVersion: String,
        using dependencies: Dependencies
    ) throws -> ReprocessResult {
        guard
            var record: UnsupportedMessageRecord = try UnsupportedMessageRecord
                .filter(UnsupportedMessageRecord.Columns.id == recordId)
                .fetchOne(db)
        else { return .missing }

        let processedMessage: ProcessedMessage

        do {
            processedMessage = try MessageReceiver.parse(
                data: record.data,
                origin: .swarm(
                    publicKey: record.swarmPublicKey,
                    namespace: (Network.StorageServer.Namespace(rawValue: record.namespace) ?? .default),
                    serverHash: record.hash,
                    serverTimestampMs: record.serverTimestampMs,
                    serverExpirationTimestamp: TimeInterval(Double(record.serverExpiryMs ?? 0) / 1000)
                ),
                using: dependencies
            )
        }
        catch {
            return try markFailed(db, record: &record, currentVersion: currentVersion, error: error)
        }

        guard
            case .standard(let threadId, let threadVariant, let messageInfo, _) = processedMessage,
            !(messageInfo.message is UnsupportedMessage)
        else {
            record.lastAttemptVersion = currentVersion
            try record.update(db)
            return .stillUnsupported
        }

        let placeholderWasRead: Bool = try record.placeholderMessageId
            .map { id in
                try Interaction
                    .select(.wasRead)
                    .filter(id: id)
                    .asRequest(of: Bool.self)
                    .fetchOne(db)
            }
            .flatMap { $0 } ?? false

        do {
            try db.inSavepoint {
                /// Remove the placeholder (which cascades to the record) so the replayed message doesn't collide with it, the replay
                /// has the same sent timestamp so it takes the same position in the conversation
                if let placeholderMessageId: Int64 = record.placeholderMessageId {
                    try LoggingDatabaseRecordContext.$suppressLogs.withValue(true) {
                        try Interaction.filter(id: placeholderMessageId).deleteAll(db)
                    }
                    db.addMessageEvent(id: placeholderMessageId, threadId: threadId, type: .deleted)
                }

                try UnsupportedMessageRecord.filter(UnsupportedMessageRecord.Columns.id == recordId).deleteAll(db)

                let insertedInteractionInfo: MessageReceiver.InsertedInteractionInfo? = try MessageReceiver.handle(
                    db,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    message: messageInfo.message,
                    decodedMessage: messageInfo.decodedMessage,
                    serverExpirationTimestamp: messageInfo.serverExpirationTimestamp,
                    suppressNotifications: true,    /// The user was already notified about the placeholder
                    currentUserSessionIds: [dependencies[cache: .general].sessionId.hexString],
                    using: dependencies
                )

                if placeholderWasRead, let interactionId: Int64 = insertedInteractionInfo?.interactionId {
                    try Interaction
                        .filter(id: interactionId)
                        .updateAll(db, Interaction.Columns.wasRead.set(to: true))
                }

                return .commit
            }
        }
        catch {
            /// The savepoint rolled back so the placeholder and record are both still in place
            return try markFailed(db, record: &record, currentVersion: currentVersion, error: error)
        }

        return .replaced
    }

    /// A failure might be specific to this version, or unrelated to the message (eg. the sender is now blocked), so the record is
    /// kept rather than dropped - it's only attempted again by a later version, and the retention limits still bound it
    private static func markFailed(
        _ db: ObservingDatabase,
        record: inout UnsupportedMessageRecord,
        currentVersion: String,
        error: Error
    ) throws -> ReprocessResult {
        Log.warn(.cat, "Failed to reprocess retained message \(record.hash) due to error: \(error).")
        record.lastAttemptVersion = currentVersion
        try record.update(db)

        return .failed
    }
}
