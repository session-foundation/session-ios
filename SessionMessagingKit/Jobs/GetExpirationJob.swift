// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionNetworkingKit
import SessionUtilitiesKit

public enum GetExpirationJob: JobExecutor {
    public static var maxFailureCount: Int = -1
    public static var requiresThreadId: Bool = true
    public static var requiresInteractionId: Bool = false
    private static let minRunFrequency: TimeInterval = 5
    
    private struct ExpirationInteractionInfo: Codable, Hashable, FetchableRecord {
        let id: Int64
        let threadId: String
        let expiresInSeconds: TimeInterval
        let expiresStartedAtMs: Double
    }
    
    public static func canRunConcurrentlyWith(
        runningJobs: [JobState],
        jobState: JobState,
        using dependencies: Dependencies
    ) -> Bool {
        return true
    }
    
    public static func run(_ job: Job, using dependencies: Dependencies) async throws -> JobExecutionResult {
        guard
            let threadId: String = job.threadId,
            let detailsData: Data = job.details,
            let details: Details = try? JSONDecoder(using: dependencies).decode(Details.self, from: detailsData)
        else { throw JobRunnerError.missingRequiredDetails }
        
        /// Ensure the messages associated to the hashes still exist
        let expectedHashes: Set<String> = Set(details.expirationInfo.keys)
        let existingHashes: Set<String> = try await dependencies[singleton: .storage].readAsync { db in
            try Interaction
                .select(.serverHash)
                .filter(expectedHashes.contains(Interaction.Columns.serverHash))
                .asRequest(of: String.self)
                .fetchSet(db)
        }
        try Task.checkCancellation()
        
        guard !existingHashes.isEmpty else {
            return .success
        }
        
        /// Recreate the `expirationInfo` only including the existing hashes
        let expirationInfo: [String: Double] = details.expirationInfo.reduce(into: [:]) { result, next in
            guard existingHashes.contains(next.key) else { return }
            
            result[next.key] = next.value
        }
        
        let request = try Network.SnodeAPI.preparedGetExpiries(
            of: Array(expirationInfo.keys),
            authMethod: try Authentication.with(
                swarmPublicKey: dependencies[cache: .general].sessionId.hexString,
                using: dependencies
            ),
            using: dependencies
        )
        
        // FIXME: Make this async/await when the refactored networking is merged
        let response: GetExpiriesResponse = try await request
            .send(using: dependencies)
            .values
            .first(where: { _ in true })?.1 ?? { throw NetworkError.invalidResponse }()
        try Task.checkCancellation()
        
        let serverSpecifiedExpirationStartTimesMs: [String: Double] = response.expiries
            .reduce(into: [:]) { result, next in
                guard let expiresInSeconds: Double = expirationInfo[next.key] else { return }
                
                result[next.key] = Double(next.value - UInt64(expiresInSeconds * 1000))
            }
        var hashesWithNoExpirationInfo: Set<String> = Set(expirationInfo.keys)
            .subtracting(serverSpecifiedExpirationStartTimesMs.keys)
        
        /// Update the message expiration info in the database
        try await dependencies[singleton: .storage].writeAsync { db in
            try serverSpecifiedExpirationStartTimesMs.forEach { hash, expiresStartedAtMs in
                try Interaction
                    .filter(Interaction.Columns.serverHash == hash)
                    .updateAll(
                        db,
                        Interaction.Columns.expiresStartedAtMs.set(to: expiresStartedAtMs)
                    )
            }
            try Task.checkCancellation()
            
            /// If we have messages which didn't get expiration values then it's possible they have already expired, so try to infer
            /// which messages they might be
            let inferredExpiredMessageHashes: Set<String> = ((try? Interaction
                .select(.serverHash)
                .filter(hashesWithNoExpirationInfo.contains(Interaction.Columns.serverHash))
                .filter(Interaction.Columns.timestampMs + (Interaction.Columns.expiresInSeconds * 1000) <= details.startedAtTimestampMs)
                .asRequest(of: String.self)
                .fetchSet(db)) ?? [])
            try Task.checkCancellation()
            
            /// We found some so we should delete them as they likely expired before we retrieved their "proper" expiration
            if !inferredExpiredMessageHashes.isEmpty {
                hashesWithNoExpirationInfo.subtract(inferredExpiredMessageHashes)
                
                try Interaction.deleteWhere(
                    db,
                    .filter(inferredExpiredMessageHashes.contains(Interaction.Columns.serverHash))
                )
            }
            try Task.checkCancellation()
            
            /// If we still have messages that have no expiration info then we should start their expiration timers just in case
            try Interaction
                .filter(hashesWithNoExpirationInfo.contains(Interaction.Columns.serverHash))
                .filter(Interaction.Columns.expiresStartedAtMs == nil)
                .updateAll(
                    db,
                    Interaction.Columns.expiresStartedAtMs.set(to: details.startedAtTimestampMs)
                )
            try Task.checkCancellation()
            
            /// Send events that the expiration started
            let allHashes: Set<String> = hashesWithNoExpirationInfo
                .inserting(contentsOf: Set(serverSpecifiedExpirationStartTimesMs.keys))
            let interactionInfo: [ExpirationInteractionInfo] = ((try? Interaction
                .select(.id, .threadId, .expiresInSeconds, .expiresStartedAtMs)
                .filter(allHashes.contains(Interaction.Columns.serverHash))
                .filter(Interaction.Columns.expiresInSeconds != nil)
                .filter(Interaction.Columns.expiresStartedAtMs != nil)
                .asRequest(of: ExpirationInteractionInfo.self)
                .fetchAll(db)) ?? [])
            try Task.checkCancellation()
            
            interactionInfo.forEach { info in
                db.addMessageEvent(
                    id: info.id,
                    threadId: info.threadId,
                    type: .updated(.expirationTimerStarted(info.expiresInSeconds, info.expiresStartedAtMs))
                )
            }
            
            /// Schedule a new job to try to get the expiration for the remaining messages without expiration info just in case we
            /// happened to hit a node which didn't have the messages we were looking for
            if !hashesWithNoExpirationInfo.isEmpty {
                dependencies[singleton: .jobRunner].add(
                    db,
                    job: Job(
                        variant: .getExpiration,
                        threadId: threadId,
                        details: GetExpirationJob.Details(
                            expirationInfo: expirationInfo,
                            startedAtTimestampMs: details.startedAtTimestampMs
                        )
                    ),
                    initialDependencies: [
                        .timestamp(waitUntil: (dependencies.dateNow.timeIntervalSince1970 + minRunFrequency))
                    ]
                )
                try Task.checkCancellation()
            }
            
            db.afterCommit {
                Task(priority: .medium) {
                    await DisappearingMessagesJob.scheduleNextRunIfNeeded(using: dependencies)
                }
            }
        }
        try Task.checkCancellation()
        
        return .success
    }
}

// MARK: - GetExpirationJob.Details

extension GetExpirationJob {
    public struct Details: Codable {
        private enum CodingKeys: String, CodingKey {
            case expirationInfo
            case startedAtTimestampMs
        }
        
        public let expirationInfo: [String: Double]
        public let startedAtTimestampMs: Double
        
        // MARK: - Initialization
        
        public init(
            expirationInfo: [String: Double],
            startedAtTimestampMs: Double
        ) {
            self.expirationInfo = expirationInfo
            self.startedAtTimestampMs = startedAtTimestampMs
        }
        
        // MARK: - Codable
        
        public init(from decoder: Decoder) throws {
            let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
            
            self = Details(
                expirationInfo: try container.decode([String: Double].self, forKey: .expirationInfo),
                startedAtTimestampMs: try container.decode(Double.self, forKey: .startedAtTimestampMs)
            )
        }
        
        public func encode(to encoder: Encoder) throws {
            var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)

            try container.encode(expirationInfo, forKey: .expirationInfo)
            try container.encode(startedAtTimestampMs, forKey: .startedAtTimestampMs)
        }
    }
}

