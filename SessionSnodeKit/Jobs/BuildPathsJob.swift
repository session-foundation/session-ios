// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUtilitiesKit

public enum BuildPathsJob: JobExecutor {
    public static let maxFailureCount: Int = 0
    public static let requiresThreadId: Bool = false
    public static let requiresInteractionId: Bool = false
    
    /// The number of paths to maintain.
    public static let targetPathCount: UInt = 2

    /// The number of guard snodes required to maintain `targetPathCount` paths.
    private static var targetGuardSnodeCount: Int { return Int(targetPathCount) } // One per path
    
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
            let details: Details = try? JSONDecoder().decode(Details.self, from: detailsData),
            let ed25519SecretKey: [UInt8] = details.ed25519SecretKey
        else {
            SNLog("[BuildPathsJob] Failing due to missing details.")
            return failure(job, JobRunnerError.missingRequiredDetails, true, dependencies)
        }
        
        SNLog("[BuildPathsJob] Starting.")
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .buildingPaths, object: nil)
        }
        
        /// First we need to get the guard snodes
        getGuardSnodes(
            reusableGuardSnodes: details.reusablePaths.map { $0[0] },
            ed25519SecretKey: ed25519SecretKey,
            queue: queue,
            using: dependencies
        )
        .tryMap { (guardSnodes: Set<Snode>) -> [[Snode]] in
            var unusedSnodes: Set<Snode> = SnodeAPI.snodePool.wrappedValue
                .subtracting(guardSnodes)
                .subtracting(details.reusablePaths.flatMap { $0 })
            let pathSnodeCount: Int = (targetGuardSnodeCount - details.reusablePaths.count) * OnionRequestAPI.pathSize - (targetGuardSnodeCount - details.reusablePaths.count)
            
            guard unusedSnodes.count >= pathSnodeCount else {
                throw SnodeAPIError.insufficientSnodes
            }
            
            /// Don't test path snodes as this would reveal the user's IP to them
            return guardSnodes
                .subtracting(details.reusablePaths.compactMap { $0.first })
                .map { (guardSnode: Snode) -> [Snode] in
                    let additionalSnodes: [Snode] = (0..<(OnionRequestAPI.pathSize - 1)).map { _ in
                        /// randomElement() uses the system's default random generator, which is cryptographically secure, the
                        /// force-unwrap here is safe because of the `pathSnodeCount` check above
                        unusedSnodes.popRandomElement()!
                    }
                    let result: [Snode] = [guardSnode].appending(contentsOf: additionalSnodes)
                    SNLog("[BuildPathsJob] Built new onion request path: \(result.prettifiedDescription).")
                    return result
                }
        }
        .subscribe(on: queue, using: dependencies)
        .receive(on: queue, using: dependencies)
        .sinkUntilComplete(
            receiveCompletion: { result in
                switch result {
                    case .finished: break
                    case .failure(let error):
                        SNLog("[BuildPathsJob] Failed due to error: \(error)")
                        failure(job, error, false, dependencies)
                }
            },
            receiveValue: { (output: [[Snode]]) in
                OnionRequestAPI.paths = (output + details.reusablePaths)
                
                dependencies.storage.write(using: dependencies) { db in
                    SNLog("[BuildPathsJob] Persisting onion request paths to database.")
                    try? output.save(db)
                }
                
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .pathsBuilt, object: nil)
                }
                
                SNLog("[BuildPathsJob] Complete.")
                success(job, false, dependencies)
            }
        )
    }
    
    private static func getGuardSnodes(
        reusableGuardSnodes: [Snode],
        ed25519SecretKey: [UInt8],
        queue: DispatchQueue,
        using dependencies: Dependencies
    ) -> AnyPublisher<Set<Snode>, Error> {
        guard OnionRequestAPI.guardSnodes.wrappedValue.count < targetGuardSnodeCount else {
            return Just(OnionRequestAPI.guardSnodes.wrappedValue)
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
        
        return Deferred {
            Future<(unusedSnodes: Set<Snode>, requiredGuardNodes: Int), Error> { resolver in
                SNLog("[BuildPathsJob] Populating guard snode cache.")
                let unusedSnodes: Set<Snode> = SnodeAPI.snodePool.wrappedValue.subtracting(reusableGuardSnodes)
                let requiredGuardNodes: Int = (targetGuardSnodeCount - reusableGuardSnodes.count)
                
                guard unusedSnodes.count >= requiredGuardNodes else {
                    return resolver(Result.failure(SnodeAPIError.insufficientSnodes))
                }
                
                resolver(Result.success((unusedSnodes, requiredGuardNodes)))
            }
        }
        .flatMap { originalUnusedSnodes, requiredGuardNodes -> AnyPublisher<Set<Snode>, Error> in
            var unusedSnodes: Set<Snode> = originalUnusedSnodes
            
            func getGuardSnode() -> AnyPublisher<Snode, Error> {
                // randomElement() uses the system's default random generator, which
                // is cryptographically secure
                guard let candidate = unusedSnodes.randomElement() else {
                    return Fail(error: SnodeAPIError.insufficientSnodes)
                        .eraseToAnyPublisher()
                }
                
                unusedSnodes.remove(candidate) // All used snodes should be unique
                SNLog("[BuildPathsJob] Testing guard snode: \(candidate).")
                
                // Loop until a reliable guard snode is found
                return SnodeAPI
                    .testSnode(
                        snode: candidate,
                        ed25519SecretKey: ed25519SecretKey,
                        using: dependencies
                    )
                    .map { _ in candidate }
                    .catch { _ in
                        return Just(())
                            .setFailureType(to: Error.self)
                            .delay(for: .milliseconds(100), scheduler: queue)
                            .flatMap { _ in getGuardSnode() }
                    }
                    .eraseToAnyPublisher()
            }
            
            return Publishers
                .MergeMany((0..<requiredGuardNodes).map { _ in getGuardSnode() })
                .collect()
                .map { output in Set(output) }
                .handleEvents(
                    receiveOutput: { output in
                        OnionRequestAPI.guardSnodes.mutate { $0 = output }
                    }
                )
                .eraseToAnyPublisher()
        }
        .eraseToAnyPublisher()
    }
    
    public static func runIfNeeded(
        excluding snodeToExclude: Snode? = nil,
        ed25519SecretKey: [UInt8]?,
        using dependencies: Dependencies
    ) -> AnyPublisher<Void, Error> {
        let paths: [[Snode]] = OnionRequestAPI.paths
        
        // Ensure the `guardSnodes` is up to date
        if !paths.isEmpty {
            OnionRequestAPI.guardSnodes.mutate {
                $0.formUnion([ paths[0][0] ])
                
                if paths.count >= 2 {
                    $0.formUnion([ paths[1][0] ])
                }
            }
        }
        
        // If we have enough paths then no need to do anything
        guard paths.count < targetPathCount else {
            return Just(())
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
        
        return Deferred {
            Future<Void, Error> { resolver in
                let hasValidPath: Bool = snodeToExclude
                    .map { snode in paths.contains { !$0.contains(snode) } }
                    .defaulting(to: !paths.isEmpty)
                
                let targetJob: Job? = dependencies.storage.write(using: dependencies) { db in
                    return dependencies.jobRunner.upsert(
                        db,
                        job: Job(
                            variant: .buildPaths,
                            behaviour: .runOnceTransient,
                            shouldBeUnique: true,
                            details: Details(reusablePaths: paths, ed25519SecretKey: ed25519SecretKey)
                        ),
                        canStartJob: true,
                        using: dependencies
                    )
                }
                
                guard let job: Job = targetJob else {
                    SNLog("[BuildPathsJob] Failed to retrieve existing job or schedule a new one.")
                    return resolver(Result.failure(JobRunnerError.generic))
                }
                
                // If we don't have a valid path then we should block this request until we have rebuilt
                // the paths
                guard hasValidPath else {
                    dependencies.jobRunner.afterJob(job) { result in
                        switch result {
                            case .succeeded: resolver(Result.success(()))
                            case .failed(let error, _): resolver(Result.failure(error ?? JobRunnerError.generic))
                            case .deferred, .notFound: resolver(Result.failure(JobRunnerError.generic))
                        }
                    }
                    return
                }
                
                // Otherwise we can let the `BuildPathsJob` run in the background and should just return
                // immediately
                SNLog("[BuildPathsJob] Scheduled in background due to existing valid path.")
                resolver(Result.success(()))
            }
        }.eraseToAnyPublisher()
    }
}

// MARK: - BuildPathsJob.Details

extension BuildPathsJob {
    public struct Details: Codable, UniqueHashable {
        private enum CodingKeys: String, CodingKey {
            case reusablePaths
            case ed25519SecretKey
        }
        
        fileprivate let reusablePaths: [[Snode]]
        fileprivate let ed25519SecretKey: [UInt8]?
        
        // MARK: - UniqueHashable
        
        /// We want the `BuildPathsJob` to be unique regardless of what data is given to it
        public var customHash: Int {
            var hasher: Hasher = Hasher()
            "BuildPathsJob.Details".hash(into: &hasher)
            return hasher.finalize()
        }
    }
}
