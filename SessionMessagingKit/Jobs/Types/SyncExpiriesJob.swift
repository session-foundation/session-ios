// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import PromiseKit
import SignalCoreKit
import SessionUtilitiesKit
import SessionSnodeKit

public enum SyncExpiriesJob: JobExecutor {
    public static let maxFailureCount: Int = 10
    public static let requiresThreadId: Bool = false
    public static let requiresInteractionId: Bool = false
    
    public static func run(
        _ job: Job,
        queue: DispatchQueue,
        success: @escaping (Job, Bool) -> (),
        failure: @escaping (Job, Error?, Bool) -> (),
        deferred: @escaping (Job) -> ()
    ) {
        guard
            let detailsData: Data = job.details,
            let details: Details = try? JSONDecoder().decode(Details.self, from: detailsData)
        else {
            failure(job, JobRunnerError.missingRequiredDetails, false)
            return
        }
        
        guard DisappearingMessagesConfiguration.isNewConfigurationEnabled else { return }
        
        var interactionIdsWithNoServerHashByExpiresInSeconds: [TimeInterval: [Int64]] = [:]
        
        details.interactionIdsByExpiresInSeconds.forEach { expiresInSeconds, interactionIds in
            guard let interactions = Storage.shared.read({ db in try? Interaction.fetchAll(db, ids: interactionIds) }) else { return }
            
            let interactionIdsWithNoServerHash: [Int64] = interactions.compactMap { $0.serverHash == nil ? $0.id : nil }
            if !interactionIdsWithNoServerHash.isEmpty {
                interactionIdsWithNoServerHashByExpiresInSeconds[expiresInSeconds] = interactionIdsWithNoServerHash
            }
            
            let serverHashes = interactions.compactMap { $0.serverHash }
            guard !serverHashes.isEmpty else { return }
            
            let expirationTimestamp: Int64 = Int64(ceil(details.startedAtMs + expiresInSeconds * 1000))
            let userPublicKey: String = getUserHexEncodedPublicKey()
            
            // Send SyncExpiriesMessage
            let syncTarget: String = interactions[0].authorId
            let syncExpiries: [SyncedExpiriesMessage.SyncedExpiry] = serverHashes.map { serverHash in
                return SyncedExpiriesMessage.SyncedExpiry(
                    serverHash: serverHash,
                    expirationTimestamp: expirationTimestamp)
            }
            
            let syncExpiriesMessage = SyncedExpiriesMessage(
                conversationExpiries: [syncTarget: syncExpiries]
            )
            
            Storage.shared.writeAsync { db in
                MessageSender
                    .send(
                        db,
                        message: syncExpiriesMessage,
                        threadId: details.threadId,
                        interactionId: nil,
                        to: .contact(publicKey: userPublicKey)
                    )
            }
            
            // Update the ttls
            SnodeAPI.updateExpiry(
                publicKey: userPublicKey,
                updatedExpiryMs: expirationTimestamp,
                serverHashes: serverHashes
            ).retainUntilComplete()
        }
        
        guard !interactionIdsWithNoServerHashByExpiresInSeconds.isEmpty else { return }
        
        Storage.shared.writeAsync { db in
            JobRunner.upsert(
                db,
                job: Job(
                    variant: .syncExpires,
                    details: SyncExpiriesJob.Details(
                        interactionIdsByExpiresInSeconds: interactionIdsWithNoServerHashByExpiresInSeconds,
                        startedAtMs: details.startedAtMs,
                        threadId: details.threadId
                    )
                )
            )
        }
    }
}

// MARK: - SyncExpiriesJob.Details

extension SyncExpiriesJob {
    public struct Details: Codable {
        private enum CodingKeys: String, CodingKey {
            case interactionIdsByExpiresInSeconds
            case startedAtMs
            case threadId
        }
        
        public let interactionIdsByExpiresInSeconds: [TimeInterval: [Int64]]
        public let startedAtMs: Double
        public let threadId: String
        
        // MARK: - Initialization
        
        public init(
            interactionIdsByExpiresInSeconds: [TimeInterval: [Int64]],
            startedAtMs: Double,
            threadId: String
        ) {
            self.interactionIdsByExpiresInSeconds = interactionIdsByExpiresInSeconds
            self.startedAtMs = startedAtMs
            self.threadId = threadId
        }
        
        // MARK: - Codable
        
        public init(from decoder: Decoder) throws {
            let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
            
            self = Details(
                interactionIdsByExpiresInSeconds: try container.decode(
                    [TimeInterval: [Int64]].self,
                    forKey: .interactionIdsByExpiresInSeconds
                ),
                startedAtMs: try container.decode(
                    Double.self,
                    forKey: .startedAtMs
                ),
                threadId: try container.decode(
                    String.self,
                    forKey: .threadId
                )
            )
        }
        
        public func encode(to encoder: Encoder) throws {
            var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
            
            try container.encode(interactionIdsByExpiresInSeconds, forKey: .interactionIdsByExpiresInSeconds)
            try container.encode(startedAtMs, forKey: .startedAtMs)
            try container.encode(threadId, forKey: .threadId)
        }
    }
}

