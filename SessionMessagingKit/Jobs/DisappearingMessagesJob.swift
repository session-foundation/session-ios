// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUtilitiesKit
import SessionNetworkingKit

// MARK: - Log.Category

private extension Log.Category {
    static let cat: Log.Category = .create("DisappearingMessagesJob", defaultLevel: .info)
}

// MARK: - DisappearingMessagesJob

public enum DisappearingMessagesJob: JobExecutor {
    public static let maxFailureCount: Int = -1
    public static let requiresThreadId: Bool = false
    public static let requiresInteractionId: Bool = false
    
    public static func canStart(
        jobState: JobState,
        alongside runningJobs: [JobState],
        using dependencies: Dependencies
    ) -> Bool {
        /// The job fetches expired messages so running multiple at once is pointless
        return false
    }
    
    public static func run(_ job: Job, using dependencies: Dependencies) async throws -> JobExecutionResult {
        guard dependencies[cache: .general].userExists else {
            return .success
        }
        
        var backgroundTask: SessionBackgroundTask? = SessionBackgroundTask(label: #function, using: dependencies)
        let timestampNowMs: Double = dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
        let numDeleted: Int = try await dependencies[singleton: .storage].writeAsync { db in
            try Interaction.deleteWhere(
                db,
                .filter(Interaction.Columns.expiresStartedAtMs != nil),
                .filter((Interaction.Columns.expiresStartedAtMs + (Interaction.Columns.expiresInSeconds * 1000)) <= timestampNowMs)
            )
        }
        try Task.checkCancellation()
        
        /// Schedule the next `DisappearingMessagesJob` run (if one is needed)
        await scheduleNextRunIfNeeded(using: dependencies)
        try Task.checkCancellation()
        
        /// The 'if' is only there to prevent the "variable never read" warning from showing
        if backgroundTask != nil { backgroundTask = nil }
        
        Log.info(.cat, "Deleted \(numDeleted) expired messages")
        return .success
    }
}

private struct InteractionThreadInfo: Codable, FetchableRecord, Hashable {
    let id: Int64
    let threadId: String
}

// MARK: - Clean expired messages on app launch

public extension DisappearingMessagesJob {
    static func cleanExpiredMessagesOnResume(using dependencies: Dependencies) {
        guard dependencies[cache: .general].userExists else { return }
        
        let timestampNowMs: Double = dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
        var numDeleted: Int = -1
        
        dependencies[singleton: .storage].write { db in
            numDeleted = try Interaction.deleteWhere(
                db,
                .filter(Interaction.Columns.expiresStartedAtMs != nil),
                .filter((Interaction.Columns.expiresStartedAtMs + (Interaction.Columns.expiresInSeconds * 1000)) <= timestampNowMs)
            )
        }
        
        Log.info(.cat, "Deleted \(numDeleted) expired messages on app resume.")
    }
}

// MARK: - Convenience

public extension DisappearingMessagesJob {
    static func scheduleNextRunIfNeeded(using dependencies: Dependencies) async {
        /// If there are any expiring messages then we want to ensure there is a job ready to run once it expires
        let nextExpirationTimestampMs: Double? = try? await dependencies[singleton: .storage].readAsync { db in
            try? Interaction
                .filter(Interaction.Columns.expiresStartedAtMs != nil)
                .filter(Interaction.Columns.expiresInSeconds != 0)
                .select(Interaction.Columns.expiresStartedAtMs + (Interaction.Columns.expiresInSeconds * 1000))
                .order((Interaction.Columns.expiresStartedAtMs + (Interaction.Columns.expiresInSeconds * 1000)).asc)
                .asRequest(of: Double.self)
                .fetchOne(db)
        }
        guard !Task.isCancelled else { return }
        
        guard let nextExpirationTimestampMs: Double = nextExpirationTimestampMs else {
            Log.info(.cat, "No remaining expiring messages")
            return
        }
        
        let existingJobState: JobState? = await dependencies[singleton: .jobRunner].firstJobMatching(
            filters: JobRunner.Filters(
                include: [
                    .variant(.disappearingMessages),
                    .executionPhase(.pending)
                ]
            )
        )
        guard !Task.isCancelled else { return }
        
        /// The `expiresStartedAtMs` timestamp is now based on the
        /// `dependencies[cache: .snodeAPI].currentOffsetTimestampMs()`
        /// value so we need to make sure offset the `nextRunTimestamp` accordingly to
        /// ensure it runs at the correct local time
        let clockOffsetMs: Int64 = dependencies[cache: .snodeAPI].clockOffsetMs
        let nextRunTimestamp: TimeInterval = (ceil((nextExpirationTimestampMs - Double(clockOffsetMs)) / 1000))
        
        try? await dependencies[singleton: .storage].writeAsync { db in
            if let existingJobId: Int64 = existingJobState?.job.id {
                try dependencies[singleton: .jobRunner].addJobDependency(
                    db,
                    .timestamp(jobId: existingJobId, waitUntil: nextRunTimestamp)
                )
            }
            else {
                dependencies[singleton: .jobRunner].add(
                    db,
                    job: Job(
                        variant: .disappearingMessages
                    ),
                    initialDependencies: [
                        .timestamp(waitUntil: nextRunTimestamp)
                    ]
                )
            }
        }
        guard !Task.isCancelled else { return }
        Log.info(.cat, "\(existingJobState != nil ? "Rescheduled" : "Scheduled") future message expiration")
    }
    
    static func retrieveExpirationInfo(
        _ db: ObservingDatabase,
        lastReadTimestampMs: Int64,
        threadId: String,
        using dependencies: Dependencies
    ) {
        struct ExpirationInfo: Codable, Hashable, FetchableRecord {
            let expiresInSeconds: TimeInterval
            let serverHash: String
        }
        let expirationInfo: [String: TimeInterval] = (try? Interaction
            .filter(
                Interaction.Columns.threadId == threadId &&
                Interaction.Columns.timestampMs <= lastReadTimestampMs &&
                Interaction.Columns.expiresInSeconds != 0 &&
                Interaction.Columns.expiresStartedAtMs == nil
            )
            .select(
                Interaction.Columns.expiresInSeconds,
                Interaction.Columns.serverHash
            )
            .asRequest(of: ExpirationInfo.self)
            .fetchAll(db))
            .defaulting(to: [])
            .grouped(by: \.serverHash)
            .compactMapValues { $0.first?.expiresInSeconds }
        
        guard !expirationInfo.isEmpty else { return }
        
        dependencies[singleton: .jobRunner].add(
            db,
            job: Job(
                variant: .getExpiration,
                threadId: threadId,
                details: GetExpirationJob.Details(
                    expirationInfo: expirationInfo,
                    startedAtTimestampMs: dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
                )
            )
        )
    }
    
    static func startExpirationIfNeeded(
        _ db: ObservingDatabase,
        interactionIds: [Int64],
        startedAtMs: Double,
        threadId: String,
        using dependencies: Dependencies
    ) {
        struct ExpirationInfo: Codable, Hashable, FetchableRecord {
            let id: Int64
            let expiresInSeconds: TimeInterval
            let serverHash: String
        }
        
        let interactionExpirationInfosByExpiresInSeconds: [TimeInterval: [ExpirationInfo]] = (try? Interaction
            .filter(interactionIds.contains(Interaction.Columns.id))
            .filter(
                Interaction.Columns.expiresInSeconds != 0 &&
                Interaction.Columns.expiresStartedAtMs == nil
            )
            .select(
                Interaction.Columns.id,
                Interaction.Columns.expiresInSeconds,
                Interaction.Columns.serverHash
            )
            .asRequest(of: ExpirationInfo.self)
            .fetchAll(db))
            .defaulting(to: [])
            .grouped(by: \.expiresInSeconds)
        
        /// Update the expiring messages `expiresStartedAtMs` value
        let changeCount: Int? = try? Interaction
            .filter(interactionIds.contains(Interaction.Columns.id))
            .filter(
                Interaction.Columns.expiresInSeconds != 0 &&
                Interaction.Columns.expiresStartedAtMs == nil
            )
            .updateAll(
                db,
                Interaction.Columns.expiresStartedAtMs.set(to: startedAtMs)
            )
        
        /// If there were no changes then none of the provided `interactionIds` are expiring messages
        guard (changeCount ?? 0) > 0 else { return }
        
        interactionExpirationInfosByExpiresInSeconds.flatMap { _, value in value }.forEach { info in
            db.addMessageEvent(
                id: info.id,
                threadId: threadId,
                type: .updated(.expirationTimerStarted(info.expiresInSeconds, startedAtMs)))
        }
        
        interactionExpirationInfosByExpiresInSeconds.forEach { expiresInSeconds, expirationInfos in
            let expirationTimestampMs: Int64 = Int64(startedAtMs + expiresInSeconds * 1000)
            dependencies[singleton: .jobRunner].add(
                db,
                job: Job(
                    variant: .expirationUpdate,
                    threadId: threadId,
                    details: ExpirationUpdateJob.Details(
                        serverHashes: expirationInfos.map { $0.serverHash },
                        expirationTimestampMs: expirationTimestampMs
                    )
                )
            )
        }
        
        db.afterCommit {
            Task.detached(priority: .medium) {
                await DisappearingMessagesJob.scheduleNextRunIfNeeded(using: dependencies)
            }
        }
    }
    
    static func startExpirationIfNeeded(
        _ db: ObservingDatabase,
        interaction: Interaction,
        startedAtMs: Double,
        using dependencies: Dependencies
    ) {
        guard interaction.isExpiringMessage else { return }
        
        /// Don't clobber if multiple actions simultaneously triggered expiration
        guard
            interaction.expiresStartedAtMs == nil ||
            (interaction.expiresStartedAtMs ?? 0) > startedAtMs
        else { return }
        
        guard let interactionId: Int64 = try? (interaction.id ?? interaction.inserted(db).id) else {
            Log.warn(.cat, "Failed to update the expiring messages timer on an interaction")
            return
        }
        
        return startExpirationIfNeeded(
            db,
            interactionIds: [interactionId],
            startedAtMs: startedAtMs,
            threadId: interaction.threadId,
            using: dependencies
        )
    }
}
