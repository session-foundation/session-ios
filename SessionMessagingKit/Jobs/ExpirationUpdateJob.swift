// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUtilitiesKit
import SessionNetworkingKit

public enum ExpirationUpdateJob: JobExecutor {
    public static var maxFailureCount: Int = -1
    public static var requiresThreadId: Bool = true
    public static var requiresInteractionId: Bool = false
    
    public static func run(_ job: Job, using dependencies: Dependencies) async throws -> JobExecutionResult {
        guard
            let detailsData: Data = job.details,
            let details: Details = try? JSONDecoder(using: dependencies).decode(Details.self, from: detailsData)
        else { throw JobRunnerError.missingRequiredDetails }
        
        do {
            let request = try Network.SnodeAPI.preparedUpdateExpiry(
                serverHashes: details.serverHashes,
                updatedExpiryMs: details.expirationTimestampMs,
                shortenOnly: true,
                authMethod: try Authentication.with(
                    swarmPublicKey: dependencies[cache: .general].sessionId.hexString,
                    using: dependencies
                ),
                using: dependencies
            )
            
            // FIXME: Refactor this to use async/await
            let response: [String: UpdateExpiryResponseResult] = try await request
                .send(using: dependencies)
                .values
                .first(where: { _ in true })?.1 ?? { throw NetworkError.invalidResponse }()
            
            let unchangedMessages: [UInt64: [String]] = response
                .compactMap { _, value in value.didError ? nil : value }
                .reduce([:], { result, next in result.updated(with: next.unchanged) })
                .groupedByValue()
            
            if !unchangedMessages.isEmpty {
                try? await dependencies[singleton: .storage].writeAsync { db in
                    unchangedMessages.forEach { updatedExpiry, hashes in
                        hashes.forEach { hash in
                            guard
                                let interaction: Interaction = try? Interaction
                                    .filter(Interaction.Columns.serverHash == hash)
                                    .fetchOne(db),
                                let expiresInSeconds: TimeInterval = interaction.expiresInSeconds
                            else { return }
                            
                            let expiresStartedAtMs: Double = Double(updatedExpiry - UInt64(expiresInSeconds * 1000))
                            
                            dependencies[singleton: .jobRunner].upsert(
                                db,
                                job: DisappearingMessagesJob.updateNextRunIfNeeded(
                                    db,
                                    interaction: interaction,
                                    startedAtMs: expiresStartedAtMs,
                                    using: dependencies
                                ),
                                canStartJob: true
                            )
                        }
                    }
                }
            }
            
            return .success(job, stop: false)
        }
        catch {
            throw JobRunnerError.permanentFailure(error)
        }
    }
}

// MARK: - ExpirationUpdateJob.Details

extension ExpirationUpdateJob {
    public struct Details: Codable {
        private enum CodingKeys: String, CodingKey {
            case serverHashes
            case expirationTimestampMs
        }
        
        public let serverHashes: [String]
        public let expirationTimestampMs: Int64
        
        // MARK: - Initialization
        
        public init(
            serverHashes: [String],
            expirationTimestampMs: Int64
        ) {
            self.serverHashes = serverHashes
            self.expirationTimestampMs = expirationTimestampMs
        }
        
        // MARK: - Codable
        
        public init(from decoder: Decoder) throws {
            let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
            
            self = Details(
                serverHashes: try container.decode([String].self, forKey: .serverHashes),
                expirationTimestampMs: try container.decode(Int64.self, forKey: .expirationTimestampMs)
            )
        }
        
        public func encode(to encoder: Encoder) throws {
            var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)

            try container.encode(serverHashes, forKey: .serverHashes)
            try container.encode(expirationTimestampMs, forKey: .expirationTimestampMs)
        }
    }
}

