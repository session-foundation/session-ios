// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUtilitiesKit

public enum GetSwarmJob: JobExecutor {
    public static let maxFailureCount: Int = 0
    public static let requiresThreadId: Bool = false
    public static let requiresInteractionId: Bool = false
    
    /// The minimum number of snodes in a swarm.
    private static let minSwarmSnodeCount: Int = 3
    
    public static func run(
        _ job: Job,
        queue: DispatchQueue,
        success: @escaping (Job, Bool, Dependencies) -> (),
        failure: @escaping (Job, Error?, Bool, Dependencies) -> (),
        deferred: @escaping (Job, Dependencies) -> (),
        using dependencies: Dependencies
    ) {
        guard
            let detailsData: Data = job.details,
            let details: Details = try? JSONDecoder().decode(Details.self, from: detailsData)
        else {
            SNLog("[GetSwarmJob] Failing due to missing details.")
            return failure(job, JobRunnerError.missingRequiredDetails, true, dependencies)
        }
        
        SNLog("[GetSwarmJob] Retrieving swarm for \(details.swarmPublicKey).")
        return SnodeAPI
            .getSwarm(for: details.swarmPublicKey, using: dependencies)
            .subscribe(on: queue, using: dependencies)
            .receive(on: queue, using: dependencies)
            .sinkUntilComplete(
                receiveCompletion: { result in
                    switch result {
                        case .finished: break
                        case .failure(let error):
                            SNLog("[GetSwarmJob] Failed due to error: \(error)")
                            failure(job, error, false, dependencies)
                    }
                },
                receiveValue: { (snodes: Set<Snode>) in
                    // Store the swarm and update the 'loadedSwarms' state so we don't fetch it again from the
                    // database the next time it's used
                    SnodeAPI.setSwarm(to: snodes, for: details.swarmPublicKey)
                    SnodeAPI.loadedSwarms.mutate { $0.insert(details.swarmPublicKey) }
                    
                    SNLog("[GetSwarmJob] Complete.")
                    success(job, false, dependencies)
                }
            )
    }
    
    public static func run(
        for swarmPublicKey: String,
        using dependencies: Dependencies
    ) -> AnyPublisher<Set<Snode>, Error> {
        // Try to load the swarm from the database if we haven't already
        if !SnodeAPI.loadedSwarms.wrappedValue.contains(swarmPublicKey) {
            let updatedCacheForKey: Set<Snode> = dependencies.storage
                .read { db in try Snode.fetchSet(db, publicKey: swarmPublicKey) }
                .defaulting(to: [])
            
            SnodeAPI.swarmCache.mutate { $0[swarmPublicKey] = updatedCacheForKey }
            SnodeAPI.loadedSwarms.mutate { $0.insert(swarmPublicKey) }
        }
        
        // If we already have a cached version of the swarm which is large enough then use that
        if let cachedSwarm = SnodeAPI.swarmCache.wrappedValue[swarmPublicKey], cachedSwarm.count >= minSwarmSnodeCount {
            return Just(cachedSwarm)
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
        
        // Otherwise trigger the job
        return Deferred {
            Future<Set<Snode>, Error> { resolver in
                let targetJob: Job? = dependencies.storage.write(using: dependencies) { db in
                    return dependencies.jobRunner.upsert(
                        db,
                        job: Job(
                            variant: .getSwarm,
                            behaviour: .runOnceTransient,
                            shouldBeUnique: true,
                            details: Details(swarmPublicKey: swarmPublicKey)
                        ),
                        canStartJob: true,
                        using: dependencies
                    )
                }
                
                guard let job: Job = targetJob else {
                    SNLog("[GetSwarmJob] Failed to retrieve existing job or schedule a new one.")
                    return resolver(Result.failure(JobRunnerError.generic))
                }
                
                dependencies.jobRunner.afterJob(job) { result in
                    switch result {
                        case .succeeded:
                            guard
                                let cachedSwarm = SnodeAPI.swarmCache.wrappedValue[swarmPublicKey],
                                cachedSwarm.count >= minSwarmSnodeCount
                            else {
                                SNLog("[GetSwarmJob] Failed to find swarm in cache after job.")
                                return resolver(Result.failure(JobRunnerError.generic))
                            }
                            
                            resolver(Result.success(cachedSwarm))
                            
                        case .failed(let error, _): resolver(Result.failure(error ?? JobRunnerError.generic))
                        case .deferred, .notFound: resolver(Result.failure(JobRunnerError.generic))
                    }
                }
            }
        }.eraseToAnyPublisher()
    }
}

// MARK: - GetSwarmJob.Details

extension GetSwarmJob {
    public struct Details: Codable {
        private enum CodingKeys: String, CodingKey {
            case swarmPublicKey
        }
        
        fileprivate let swarmPublicKey: String
    }
}
