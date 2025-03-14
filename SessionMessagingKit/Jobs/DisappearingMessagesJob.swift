// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUtilitiesKit
import SessionSnodeKit

// MARK: - Log.Category

private extension Log.Category {
    static let cat: Log.Category = .create("DisappearingMessagesJob", defaultLevel: .info)
}

// MARK: - DisappearingMessagesJob

public enum DisappearingMessagesJob: JobExecutor {
    public static let maxFailureCount: Int = -1
    public static let requiresThreadId: Bool = false
    public static let requiresInteractionId: Bool = false
    
    public static func run<S: Scheduler>(
        _ job: Job,
        scheduler: S,
        success: @escaping (Job, Bool) -> Void,
        failure: @escaping (Job, Error, Bool) -> Void,
        deferred: @escaping (Job) -> Void,
        using dependencies: Dependencies
    ) {
        guard Identity.userExists(using: dependencies) else { return success(job, false) }
        
        // The 'backgroundTask' gets captured and cleared within the 'completion' block
        let timestampNowMs: Double = dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
        var backgroundTask: SessionBackgroundTask? = SessionBackgroundTask(label: #function, using: dependencies)
        var numDeleted: Int = -1
        
        let updatedJob: Job? = dependencies[singleton: .storage].write { db in
            numDeleted = try Interaction
                .filter(Interaction.Columns.expiresStartedAtMs != nil)
                .filter((Interaction.Columns.expiresStartedAtMs + (Interaction.Columns.expiresInSeconds * 1000)) <= timestampNowMs)
                .deleteAll(db)
            
            // Update the next run timestamp for the DisappearingMessagesJob (if the call
            // to 'updateNextRunIfNeeded' returns 'nil' then it doesn't need to re-run so
            // should have it's 'nextRunTimestamp' cleared)
            return try updateNextRunIfNeeded(db, using: dependencies)
                .defaulting(to: job.with(nextRunTimestamp: 0))
                .upserted(db)
        }
        
        Log.info(.cat, "Deleted \(numDeleted) expired messages")
        success(updatedJob ?? job, false)
        
        // The 'if' is only there to prevent the "variable never read" warning from showing
        if backgroundTask != nil { backgroundTask = nil }
    }
}

// MARK: - Clean expired messages on app launch

public extension DisappearingMessagesJob {
    static func cleanExpiredMessagesOnLaunch(using dependencies: Dependencies) {
        guard Identity.userExists(using: dependencies) else { return }
        
        let timestampNowMs: Double = dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
        var numDeleted: Int = -1
        
        dependencies[singleton: .storage].write { db in
            numDeleted = try Interaction
                .filter(Interaction.Columns.expiresStartedAtMs != nil)
                .filter((Interaction.Columns.expiresStartedAtMs + (Interaction.Columns.expiresInSeconds * 1000)) <= timestampNowMs)
                .deleteAll(db)
        }
        
        Log.info(.cat, "Deleted \(numDeleted) expired messages on app launch.")
    }
}

// MARK: - Convenience

public extension DisappearingMessagesJob {
    @discardableResult static func updateNextRunIfNeeded(
        _ db: Database,
        using dependencies: Dependencies
    ) -> Job? {
        // If there is another expiring message then update the job to run 1 second after it's meant to expire
        let nextExpirationTimestampMs: Double? = try? Interaction
            .filter(Interaction.Columns.expiresStartedAtMs != nil)
            .filter(Interaction.Columns.expiresInSeconds != 0)
            .select(Interaction.Columns.expiresStartedAtMs + (Interaction.Columns.expiresInSeconds * 1000))
            .order((Interaction.Columns.expiresStartedAtMs + (Interaction.Columns.expiresInSeconds * 1000)).asc)
            .asRequest(of: Double.self)
            .fetchOne(db)
        
        guard let nextExpirationTimestampMs: Double = nextExpirationTimestampMs else {
            Log.info(.cat, "No remaining expiring messages")
            return nil
        }
        
        /// The `expiresStartedAtMs` timestamp is now based on the
        /// `dependencies[cache: .snodeAPI].currentOffsetTimestampMs()`
        /// value so we need to make sure offset the `nextRunTimestamp` accordingly to
        /// ensure it runs at the correct local time
        let clockOffsetMs: Int64 = dependencies[cache: .snodeAPI].clockOffsetMs
        
        Log.info(.cat, "Scheduled future message expiration")
        return try? Job
            .filter(Job.Columns.variant == Job.Variant.disappearingMessages)
            .fetchOne(db)?
            .with(nextRunTimestamp: ceil((nextExpirationTimestampMs - Double(clockOffsetMs)) / 1000))
            .upserted(db)
    }
    
    static func updateNextRunIfNeeded(
        _ db: Database,
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
            .compactMapValues{ $0.first?.expiresInSeconds }
        
        guard (expirationInfo.count > 0) else { return }
        
        dependencies[singleton: .jobRunner].add(
            db,
            job: Job(
                variant: .getExpiration,
                behaviour: .runOnce,
                threadId: threadId,
                details: GetExpirationJob.Details(
                    expirationInfo: expirationInfo,
                    startedAtTimestampMs: dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
                )
            ),
            canStartJob: true
        )
    }
    
    @discardableResult static func updateNextRunIfNeeded(
        _ db: Database,
        interactionIds: [Int64],
        startedAtMs: Double,
        threadId: String,
        using dependencies: Dependencies
    ) -> Job? {
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
        
        // Update the expiring messages expiresStartedAtMs value
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
        
        // If there were no changes then none of the provided `interactionIds` are expiring messages
        guard (changeCount ?? 0) > 0 else { return nil }
        
        interactionExpirationInfosByExpiresInSeconds.forEach { expiresInSeconds, expirationInfos in
            let expirationTimestampMs: Int64 = Int64(startedAtMs + expiresInSeconds * 1000)
            dependencies[singleton: .jobRunner].add(
                db,
                job: Job(
                    variant: .expirationUpdate,
                    behaviour: .runOnce,
                    threadId: threadId,
                    details: ExpirationUpdateJob.Details(
                        serverHashes: expirationInfos.map { $0.serverHash },
                        expirationTimestampMs: expirationTimestampMs
                    )
                ),
                canStartJob: true
            )
        }
        
        return updateNextRunIfNeeded(db, using: dependencies)
    }
    
    @discardableResult static func updateNextRunIfNeeded(
        _ db: Database,
        interaction: Interaction,
        startedAtMs: Double,
        using dependencies: Dependencies
    ) -> Job? {
        guard interaction.isExpiringMessage else { return nil }
        
        // Don't clobber if multiple actions simultaneously triggered expiration
        guard interaction.expiresStartedAtMs == nil || (interaction.expiresStartedAtMs ?? 0) > startedAtMs else {
            return nil
        }
        
        do {
            guard let interactionId: Int64 = try? (interaction.id ?? interaction.inserted(db).id) else {
                throw StorageError.objectNotFound
            }
            
            return updateNextRunIfNeeded(
                db,
                interactionIds: [interactionId],
                startedAtMs: startedAtMs,
                threadId: interaction.threadId,
                using: dependencies
            )
        }
        catch {
            Log.warn(.cat, "Failed to update the expiring messages timer on an interaction")
            return nil
        }
    }
}
