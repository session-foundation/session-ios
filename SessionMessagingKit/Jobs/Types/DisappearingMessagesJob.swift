// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
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
    
    @discardableResult static func updateNextRunIfNeeded(_ db: Database, lastReadTimestampMs: Int64, threadId: String) -> Job? {
        let messageHashes: [String] = (try? Interaction
            .filter(
                Interaction.Columns.threadId == threadId &&
                Interaction.Columns.timestampMs <= lastReadTimestampMs &&
                Interaction.Columns.expiresInSeconds != nil &&
                Interaction.Columns.expiresStartedAtMs == nil
            )
                .select(Interaction.Columns.serverHash)
                .fetchAll(db))
            .defaulting(to: [])
        
        // If there were no message hashes then none of the messages sent before lastReadTimestampMs are expiring messages
        guard (messageHashes.count > 0) else { return nil }
        
        // Update the expiring messages expiresStartedAtMs value
        _ = try? Interaction
            .filter(messageHashes.contains(Interaction.Columns.serverHash))
            .updateAll(
                db,
                Interaction.Columns.expiresStartedAtMs.set(to: Double(lastReadTimestampMs))
            )

        let userPublicKey: String = getUserHexEncodedPublicKey(db)
        SnodeAPI.getSwarm(for: userPublicKey)
            .tryFlatMap { swarm -> AnyPublisher<(ResponseInfoType, GetExpiriesResponse), Error> in
                guard let snode = swarm.randomElement() else { throw SnodeAPIError.generic }
                return SnodeAPI.getExpiries(
                    from: snode,
                    associatedWith: userPublicKey,
                    of: messageHashes
                )
            }
            .map { response in
                Storage.shared.writeAsync { db in
                    try response.1.expiries.forEach { hash, exipreAtMs in
                        let expiresInSeconds: TimeInterval = TimeInterval((exipreAtMs - UInt64(lastReadTimestampMs)) / 1000)
                        
                        _ = try Interaction
                            .filter(Interaction.Columns.serverHash == hash)
                            .updateAll(
                                db,
                                Interaction.Columns.expiresInSeconds.set(to: expiresInSeconds)
                            )
                    }
                }
            }
        
        return updateNextRunIfNeeded(db)
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
            .updateAll(
                db,
                Interaction.Columns.expiresStartedAtMs.set(to: startedAtMs)
            )
        
        // If there were no changes then none of the provided `interactionIds` are expiring messages
        guard (changeCount ?? 0) > 0 else { return nil }
        
        let userPublicKey: String = getUserHexEncodedPublicKey(db)
        let updateExpiryPublishers: [AnyPublisher<[String: UpdateExpiryResponseResult], Error>] = interactionExpirationInfosByExpiresInSeconds
            .map { expiresInSeconds, expirationInfos -> AnyPublisher<[String: UpdateExpiryResponseResult], Error> in
                let expirationTimestampMs: Int64 = Int64(ceil(startedAtMs + expiresInSeconds * 1000))
                
                return SnodeAPI
                    .updateExpiry(
                        publicKey: userPublicKey,
                        serverHashes: expirationInfos.map { $0.serverHash },
                        updatedExpiryMs: expirationTimestampMs,
                        shortenOnly: true
                    )
            }
        
        Publishers
            .MergeMany(updateExpiryPublishers)
            .collect()
            .sinkUntilComplete(
                receiveValue: { allResults in
                    guard
                        let results: [UpdateExpiryResponseResult] = allResults
                            .compactMap({ result in result.first(where: { _, value in !value.didError })?.value })
                            .nullIfEmpty(),
                        let unchangedMessages: [UInt64: [String]] = results
                            .reduce([:], { result, next in result.updated(with: next.unchanged) })
                            .groupedByValue()
                            .nullIfEmpty()
                    else { return }
                    
                    Storage.shared.writeAsync { db in
                        try unchangedMessages.forEach { updatedExpiry, hashes in
                            let expiresInSeconds: TimeInterval = ((TimeInterval(updatedExpiry) - startedAtMs) / 1000)
                            
                            _ = try Interaction
                                .filter(hashes.contains(Interaction.Columns.serverHash))
                                .updateAll(
                                    db,
                                    Interaction.Columns.expiresInSeconds.set(to: expiresInSeconds)
                                )
                        }
                    }
                }
            )
        
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
