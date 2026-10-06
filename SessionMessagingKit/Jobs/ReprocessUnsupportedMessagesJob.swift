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
        let recordIds: [Int64] = try await dependencies[singleton: .storage].write { db in
            try UnsupportedMessageRecord.enforceLimits(db, using: dependencies)

            return try UnsupportedMessageRecord
                .select(.id)
                .filter(UnsupportedMessageRecord.Columns.lastAttemptVersion != currentVersion)
                .asRequest(of: Int64.self)
                .fetchAll(db)
        }

        guard !recordIds.isEmpty else { return .success }

        var replacedCount: Int = 0
        var droppedCount: Int = 0

        for recordId in recordIds {
            try Task.checkCancellation()

            let result: ReprocessResult = try await dependencies[singleton: .storage].write { db in
                try reprocess(db, recordId: recordId, currentVersion: currentVersion, using: dependencies)
            }

            switch result {
                case .replaced: replacedCount += 1
                case .dropped: droppedCount += 1
                case .stillUnsupported: break
            }
        }

        Log.info(.cat, "Reprocessed \(recordIds.count) retained message(s): \(replacedCount) replaced, \(droppedCount) dropped.")
        return .success
    }

    internal enum ReprocessResult {
        case replaced
        case stillUnsupported
        case dropped
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
        else { return .dropped }

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
            /// This version can't process the message either and never will (eg. the group keys are gone), so stop retaining the
            /// bytes but leave any placeholder in place
            try UnsupportedMessageRecord.filter(UnsupportedMessageRecord.Columns.id == recordId).deleteAll(db)
            return .dropped
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
            try UnsupportedMessageRecord.filter(UnsupportedMessageRecord.Columns.id == recordId).deleteAll(db)
            return .dropped
        }

        return .replaced
    }
}
