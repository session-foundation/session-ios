// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUtilitiesKit
import SessionSnodeKit

public enum GetExpirationJob: JobExecutor {
    public static var maxFailureCount: Int = -1
    public static var requiresThreadId: Bool = true
    public static var requiresInteractionId: Bool = false
    private static let minRunFrequency: TimeInterval = 5
    
    public static func run(
        _ job: SessionUtilitiesKit.Job,
        queue: DispatchQueue,
        success: @escaping (SessionUtilitiesKit.Job, Bool) -> (),
        failure: @escaping (SessionUtilitiesKit.Job, Error?, Bool) -> (),
        deferred: @escaping (SessionUtilitiesKit.Job) -> ()
    ) {
        guard
            let detailsData: Data = job.details,
            let details: Details = try? JSONDecoder().decode(Details.self, from: detailsData)
        else {
            SNLog("[GetExpirationJob] Failing due to missing details")
            failure(job, JobRunnerError.missingRequiredDetails, true)
            return
        }
        
        var expirationInfo: [String: TimeInterval] = details.expirationInfo
        guard expirationInfo.count > 0 else {
            success(job, false)
            return
        }
        
        let userPublicKey: String = getUserHexEncodedPublicKey()
        SnodeAPI.getSwarm(for: userPublicKey)
            .tryFlatMap { swarm -> AnyPublisher<(ResponseInfoType, GetExpiriesResponse), Error> in
                guard let snode = swarm.randomElement() else { throw SnodeAPIError.generic }
                return SnodeAPI.getExpiries(
                    from: snode,
                    associatedWith: userPublicKey,
                    of: expirationInfo.map { $0.key }
                )
            }
            .subscribe(on: queue)
            .receive(on: queue)
            .map { (_, response) -> GetExpiriesResponse in
                return response
            }
            .sinkUntilComplete(
                receiveCompletion: { result in
                    switch result {
                        case .finished:
                            break
                        case .failure(let error):
                            failure(job, error, true)
                    }
                },
                receiveValue: { response in
                    Storage.shared.write { db in
                        try response.expiries.forEach { hash, expireAtMs in
                            guard let expiresInSeconds: TimeInterval = expirationInfo[hash] else { return }
                            let expiresStartedAtMs: TimeInterval = TimeInterval(expireAtMs - UInt64(expiresInSeconds * 1000))
                            
                            _ = try Interaction
                                .filter(Interaction.Columns.serverHash == hash)
                                .updateAll(
                                    db,
                                    Interaction.Columns.expiresStartedAtMs.set(to: expiresStartedAtMs)
                                )
                            
                            guard let index = expirationInfo.index(forKey: hash) else { return }
                            expirationInfo.remove(at: index)
                        }
                        
                        try expirationInfo.forEach { key, _ in
                            _ = try Interaction
                                .filter(Interaction.Columns.serverHash == key)
                                .filter(Interaction.Columns.expiresStartedAtMs == nil)
                                .updateAll(
                                    db,
                                    Interaction.Columns.expiresStartedAtMs.set(to: details.startedAtTimestampMs)
                                )
                        }
                    }
                    
                    if !expirationInfo.isEmpty {
                        let updatedJob: Job? = Storage.shared.write { db in
                            try job
                                .with(nextRunTimestamp: Date().timeIntervalSince1970 + minRunFrequency)
                                .saved(db)
                        }
                        
                        deferred(updatedJob ?? job)
                    } else {
                        success(job, false)
                    }
                }
            )
    }
}

// MARK: - GetExpirationJob.Details

extension GetExpirationJob {
    public struct Details: Codable {
        private enum CodingKeys: String, CodingKey {
            case expirationInfo
            case startedAtTimestampMs
        }
        
        public let expirationInfo: [String: TimeInterval]
        public let startedAtTimestampMs: Double
        
        // MARK: - Initialization
        
        public init(
            expirationInfo: [String: TimeInterval],
            startedAtTimestampMs: Double
        ) {
            self.expirationInfo = expirationInfo
            self.startedAtTimestampMs = startedAtTimestampMs
        }
        
        // MARK: - Codable
        
        public init(from decoder: Decoder) throws {
            let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
            
            self = Details(
                expirationInfo: try container.decode([String: TimeInterval].self, forKey: .expirationInfo),
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

