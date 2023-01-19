// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit
import SessionSnodeKit

public enum DisappearingMessagesJob: JobExecutor {
    public static let maxFailureCount: Int = -1
    public static let requiresThreadId: Bool = false
    public static let requiresInteractionId: Bool = false
    
    public static func run(
        _ job: Job,
        queue: DispatchQueue,
        success: @escaping (Job, Bool) -> (),
        failure: @escaping (Job, Error?, Bool) -> (),
        deferred: @escaping (Job) -> ()
    ) {
        // The 'backgroundTask' gets captured and cleared within the 'completion' block
        let timestampNowMs: TimeInterval = TimeInterval(SnodeAPI.currentOffsetTimestampMs())
        var backgroundTask: OWSBackgroundTask? = OWSBackgroundTask(label: #function)
        
        let updatedJob: Job? = Storage.shared.write { db in
            _ = try Interaction
                .filter(Interaction.Columns.expiresStartedAtMs != nil)
                .filter((Interaction.Columns.expiresStartedAtMs + (Interaction.Columns.expiresInSeconds * 1000)) <= timestampNowMs)
                .deleteAll(db)
            
            // Update the next run timestamp for the DisappearingMessagesJob (if the call
            // to 'updateNextRunIfNeeded' returns 'nil' then it doesn't need to re-run so
            // should have it's 'nextRunTimestamp' cleared)
            return try updateNextRunIfNeeded(db)
                .defaulting(to: job.with(nextRunTimestamp: 0))
                .saved(db)
        }
        
        success(updatedJob ?? job, false)
        
        // The 'if' is only there to prevent the "variable never read" warning from showing
        if backgroundTask != nil { backgroundTask = nil }
    }
}

// MARK: - Convenience

public extension DisappearingMessagesJob {
    @discardableResult static func updateNextRunIfNeeded(_ db: Database) -> Job? {
        // Don't run when inactive or not in main app
        guard (UserDefaults.sharedLokiProject?[.isMainAppActive]).defaulting(to: false) else { return nil }
        
        // If there is another expiring message then update the job to run 1 second after it's meant to expire
        let nextExpirationTimestampMs: Double? = try? Interaction
            .filter(Interaction.Columns.expiresStartedAtMs != nil)
            .filter(Interaction.Columns.expiresInSeconds != nil)
            .select(Interaction.Columns.expiresStartedAtMs + (Interaction.Columns.expiresInSeconds * 1000))
            .order((Interaction.Columns.expiresStartedAtMs + (Interaction.Columns.expiresInSeconds * 1000)).asc)
            .asRequest(of: Double.self)
            .fetchOne(db)
        
        guard let nextExpirationTimestampMs: Double = nextExpirationTimestampMs else { return nil }
        
        /// The `expiresStartedAtMs` timestamp is now based on the `SnodeAPI.currentOffsetTimestampMs()` value
        /// so we need to make sure offset the `nextRunTimestamp` accordingly to ensure it runs at the correct local time
        let clockOffsetMs: Int64 = SnodeAPI.clockOffsetMs.wrappedValue
        
        return try? Job
            .filter(Job.Columns.variant == Job.Variant.disappearingMessages)
            .fetchOne(db)?
            .with(nextRunTimestamp: ceil((nextExpirationTimestampMs - Double(clockOffsetMs)) / 1000))
            .saved(db)
    }
    
    @discardableResult static func updateNextRunIfNeeded(_ db: Database, interactionIds: [Int64], startedAtMs: Double, threadId: String) -> Job? {
        struct ExpirationInfo: Codable, Hashable, FetchableRecord {
            let id: Int64
            let expiresInSeconds: TimeInterval
            let serverHash: String
        }
        
        let interactionExpirationInfosByExpiresInSeconds: [TimeInterval: [ExpirationInfo]] = (try? Interaction
            .filter(interactionIds.contains(Interaction.Columns.id))
            .filter(
                Interaction.Columns.expiresInSeconds != nil &&
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
                Interaction.Columns.expiresInSeconds != nil &&
                Interaction.Columns.expiresStartedAtMs == nil
            )
            .updateAll(db, Interaction.Columns.expiresStartedAtMs.set(to: startedAtMs))
        
        // If there were no changes then none of the provided `interactionIds` are expiring messages
        guard (changeCount ?? 0) > 0 else { return nil }
        
        interactionExpirationInfosByExpiresInSeconds.forEach { expiresInSeconds, expirationInfos in
            let expirationTimestampMs: Int64 = Int64(ceil(startedAtMs + expiresInSeconds * 1000))
            
            SnodeAPI.updateExpiry(
                publicKey: getUserHexEncodedPublicKey(db),
                updatedExpiryMs: expirationTimestampMs,
                serverHashes: expirationInfos.map { $0.serverHash },
                shortenOnly: true
            ).map2 { results in
                var unchangedMessages: [String: UInt64] = [:]
                results.forEach { _, result in
                    guard let unchanged = result.unchanged else { return }
                    unchangedMessages.merge(unchanged) { (current, _) in current }
                }
                
                guard !unchangedMessages.isEmpty else { return }
                
                unchangedMessages.forEach { serverHash, serverExpirationTimestampMs in
                    let expiresInSeconds: TimeInterval = (TimeInterval(serverExpirationTimestampMs) - startedAtMs) / 1000
                    
                    _ = try? Interaction
                        .filter(Interaction.Columns.serverHash == serverHash)
                        .updateAll(db, Interaction.Columns.expiresInSeconds.set(to: expiresInSeconds))
                }
            }.retainUntilComplete()
            
            let swarm = SnodeAPI.swarmCache.wrappedValue[getUserHexEncodedPublicKey(db)] ?? []
            let snode = swarm.randomElement()!
            SnodeAPI.getExpiries(from: snode, associatedWith: getUserHexEncodedPublicKey(db), of: expirationInfos.map { $0.serverHash }).retainUntilComplete()
        }
        
        return updateNextRunIfNeeded(db)
    }
    
    @discardableResult static func updateNextRunIfNeeded(_ db: Database, interaction: Interaction, startedAtMs: Double) -> Job? {
        guard interaction.isExpiringMessage else { return nil }
        
        // Don't clobber if multiple actions simultaneously triggered expiration
        guard interaction.expiresStartedAtMs == nil || (interaction.expiresStartedAtMs ?? 0) > startedAtMs else {
            return nil
        }
        
        do {
            guard let interactionId: Int64 = try? (interaction.id ?? interaction.inserted(db).id) else {
                throw StorageError.objectNotFound
            }
            
            return updateNextRunIfNeeded(db, interactionIds: [interactionId], startedAtMs: startedAtMs, threadId: interaction.threadId)
        }
        catch {
            SNLog("Failed to update the expiring messages timer on an interaction")
            return nil
        }
    }
}
