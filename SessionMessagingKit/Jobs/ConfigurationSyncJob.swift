// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionNetworkingKit
import SessionUtilitiesKit

// MARK: - Log.Category

private extension Log.Category {
    static let cat: Log.Category = .create("ConfigurationSyncJob", defaultLevel: .info)
}

// MARK: - ConfigurationSyncJob

public enum ConfigurationSyncJob: JobExecutor {
    public static let maxFailureCount: Int = -1
    public static let requiresThreadId: Bool = true
    public static let requiresInteractionId: Bool = false
    private static let maxRunFrequency: TimeInterval = 3
    private static let waitTimeForExpirationUpdate: TimeInterval = 1
    
    public static func run<S: Scheduler>(
        _ job: Job,
        scheduler: S,
        success: @escaping (Job, Bool) -> Void,
        failure: @escaping (Job, Error, Bool) -> Void,
        deferred: @escaping (Job) -> Void,
        using dependencies: Dependencies
    ) {
        guard !dependencies[cache: .libSession].isEmpty else {
            return success(job, true)
        }
        
        /// It's possible for multiple ConfigSyncJob's with the same target (user/group) to try to run at the same time since as soon as
        /// one is started we will enqueue a second one, rather than adding dependencies between the jobs we just continue to defer
        /// the subsequent job while the first one is running in order to prevent multiple configurationSync jobs with the same target
        /// from running at the same time
        ///
        /// **Note:** The one exception to this rule is when the job has `AdditionalTransientData` because if we don't
        /// run it immediately then the `AdditionalTransientData` may not get run at all
        guard
            job.transientData != nil ||
            dependencies[singleton: .jobRunner]
                .jobInfoFor(state: .running, variant: .configurationSync)
                .filter({ key, info in
                    key != job.id &&                // Exclude this job
                    info.threadId == job.threadId   // Exclude jobs for different config stores
                })
                .isEmpty
        else {
            // Defer the job to run 'maxRunFrequency' from when this one ran (if we don't it'll try start
            // it again immediately which is pointless)
            let updatedJob: Job? = dependencies[singleton: .storage].write { db in
                try job
                    .with(nextRunTimestamp: dependencies.dateNow.timeIntervalSince1970 + maxRunFrequency)
                    .upserted(db)
            }
            
            Log.info(.cat, "For \(job.threadId ?? "UnknownId") deferred due to in progress job")
            return deferred(updatedJob ?? job)
        }
        
        // If we don't have a userKeyPair yet then there is no need to sync the configuration
        // as the user doesn't exist yet (this will get triggered on the first launch of a
        // fresh install due to the migrations getting run)
        guard
            let swarmPublicKey: String = job.threadId,
            let pendingPushes: LibSession.PendingPushes = try? dependencies.mutate(cache: .libSession, {
                try $0.pendingPushes(swarmPublicKey: swarmPublicKey)
            })
        else {
            Log.info(.cat, "For \(job.threadId ?? "UnknownId") failed due to invalid data")
            return failure(job, StorageError.generic, false)
        }
        
        /// If there is no `pushData` or additional sequence requests then the job can just complete (next time something is updated
        /// we want to try and run immediately so don't scuedule another run in this case)
        guard
            !pendingPushes.pushData.isEmpty ||
            job.transientData != nil
        else {
            Log.info(.cat, "For \(swarmPublicKey) completed with no pending changes")
            ConfigurationSyncJob.startJobsWaitingOnConfigSync(swarmPublicKey, using: dependencies)
            return success(job, true)
        }
        
        let jobStartTimestamp: TimeInterval = dependencies.dateNow.timeIntervalSince1970
        let messageSendTimestamp: Int64 = dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
        let additionalTransientData: AdditionalTransientData? = (job.transientData as? AdditionalTransientData)
        Log.info(.cat, "For \(swarmPublicKey) started with changes: \(pendingPushes.pushData.count), old hashes: \(pendingPushes.obsoleteHashes.count)")
        
        dependencies[singleton: .storage]
            .readPublisher { db -> AuthenticationMethod in
                try Authentication.with(db, swarmPublicKey: swarmPublicKey, using: dependencies)
            }
            .tryFlatMap { authMethod -> AnyPublisher<(ResponseInfoType, Network.BatchResponse), Error> in
                try Network.SnodeAPI.preparedSequence(
                    requests: []
                        .appending(contentsOf: additionalTransientData?.beforeSequenceRequests)
                        .appending(
                            contentsOf: try pendingPushes.pushData
                                .flatMap { pushData -> [ErasedPreparedRequest] in
                                    try pushData.data.map { data -> ErasedPreparedRequest in
                                        try Network.SnodeAPI
                                            .preparedSendMessage(
                                                message: SnodeMessage(
                                                    recipient: swarmPublicKey,
                                                    data: data,
                                                    ttl: pushData.variant.ttl,
                                                    timestampMs: UInt64(messageSendTimestamp)
                                                ),
                                                in: pushData.variant.namespace,
                                                authMethod: authMethod,
                                                using: dependencies
                                            )
                                    }
                            }
                        )
                        .appending(try {
                            guard !pendingPushes.obsoleteHashes.isEmpty else { return nil }
                            
                            return try Network.SnodeAPI.preparedDeleteMessages(
                                serverHashes: Array(pendingPushes.obsoleteHashes),
                                requireSuccessfulDeletion: false,
                                authMethod: authMethod,
                                using: dependencies
                            )
                        }())
                        .appending(contentsOf: additionalTransientData?.afterSequenceRequests),
                    requireAllBatchResponses: (additionalTransientData?.requireAllBatchResponses == true),
                    swarmPublicKey: swarmPublicKey,
                    snodeRetrievalRetryCount: 0,    // This job has it's own retry mechanism
                    requestAndPathBuildTimeout: Network.defaultTimeout,
                    using: dependencies
                ).send(using: dependencies)
            }
            .subscribe(on: scheduler, using: dependencies)
            .receive(on: scheduler, using: dependencies)
            .tryMap { (_: ResponseInfoType, response: Network.BatchResponse) -> [ConfigDump] in
                /// The number of responses returned might not match the number of changes sent but they will be returned
                /// in the same order, this means we can just `zip` the two arrays as it will take the smaller of the two and
                /// correctly align the response to the change (we need to manually remove any `beforeSequenceRequests`
                /// results through)
                let responseWithoutBeforeRequests = Array(response
                    .suffix(from: additionalTransientData?.beforeSequenceRequests.count ?? 0))
                
                /// If we `requireAllRequestsSucceed` then ensure every request returned a 2XX status code and
                /// was successfully parsed
                guard
                    additionalTransientData == nil ||
                    additionalTransientData?.requireAllRequestsSucceed == false ||
                    !response
                        .map({ $0 as? ErasedBatchSubResponse })
                        .contains(where: { response -> Bool in
                            (response?.code ?? 0) < 200 ||
                            (response?.code ?? 0) > 299 ||
                            response?.failedToParseBody == true
                        })
                else { throw NetworkError.invalidResponse }
                
                let results: [(pushData: LibSession.PendingPushes.PushData, hash: String?)] = zip(responseWithoutBeforeRequests, pendingPushes.pushData)
                    .map { (subResponse: Any, pushData: LibSession.PendingPushes.PushData) in
                        /// If the request wasn't successful then just ignore it (the next time we sync this config we will try
                        /// to send the changes again)
                        guard
                            let typedResponse: Network.BatchSubResponse<SendMessagesResponse> = (subResponse as? Network.BatchSubResponse<SendMessagesResponse>),
                            200...299 ~= typedResponse.code,
                            !typedResponse.failedToParseBody,
                            let sendMessageResponse: SendMessagesResponse = typedResponse.body
                        else { return (pushData, nil) }
                        
                        return (pushData, sendMessageResponse.hash)
                    }
                
                /// Since this change was successful we need to mark it as pushed and generate any config dumps
                /// which need to be stored
                return try dependencies.mutate(cache: .libSession) { cache in
                    try cache.createDumpMarkingAsPushed(
                        data: results,
                        sentTimestamp: messageSendTimestamp,
                        swarmPublicKey: swarmPublicKey
                    )
                }
            }
            .sinkUntilComplete(
                receiveCompletion: { result in
                    switch result {
                        case .finished: Log.info(.cat, "For \(swarmPublicKey) completed")
                        case .failure(let error):
                            Log.error(.cat, "For \(swarmPublicKey) failed due to error: \(error)")
                            
                            // If the failure is due to being offline then we should automatically
                            // retry if the connection is re-established
                            dependencies[cache: .libSessionNetwork].networkStatus
                                .first()
                                .sinkUntilComplete(
                                    receiveValue: { status in
                                        switch status {
                                            // If we are currently connected then use the standard
                                            // retry behaviour
                                            case .connected: failure(job, error, false)
                                                
                                            // If not then permanently fail the job and reschedule it
                                            // to run again if we re-establish the connection
                                            default:
                                                failure(job, error, true)
                                                
                                                dependencies[cache: .libSessionNetwork].networkStatus
                                                    .filter { $0 == .connected }
                                                    .first()
                                                    .sinkUntilComplete(
                                                        receiveCompletion: { _ in
                                                            dependencies[singleton: .storage].writeAsync { db in
                                                                ConfigurationSyncJob.enqueue(
                                                                    db,
                                                                    swarmPublicKey: swarmPublicKey,
                                                                    using: dependencies
                                                                )
                                                            }
                                                        }
                                                    )
                                        }
                                    }
                                )
                    }
                },
                receiveValue: { (configDumps: [ConfigDump]) in
                    // Flag to indicate whether the job should be finished or will run again
                    var shouldFinishCurrentJob: Bool = false
                    
                    // Lastly we need to save the updated dumps to the database
                    let updatedJob: Job? = dependencies[singleton: .storage].write { db in
                        // Save the updated dumps to the database
                        try configDumps.forEach { dump in
                            try dump.upsert(db)
                            Task.detached(priority: .medium) { [extensionHelper = dependencies[singleton: .extensionHelper]] in
                                extensionHelper.replicate(dump: dump)
                            }
                        }
                        
                        // When we complete the 'ConfigurationSync' job we want to immediately schedule
                        // another one with a 'nextRunTimestamp' set to the 'maxRunFrequency' value to
                        // throttle the config sync requests
                        let nextRunTimestamp: TimeInterval = (jobStartTimestamp + maxRunFrequency)
                        
                        // If another 'ConfigurationSync' job was scheduled then update that one
                        // to run at 'nextRunTimestamp' and make the current job stop
                        if
                            let existingJob: Job = try? Job
                                .filter(Job.Columns.id != job.id)
                                .filter(Job.Columns.variant == Job.Variant.configurationSync)
                                .filter(Job.Columns.threadId == swarmPublicKey)
                                .order(Job.Columns.nextRunTimestamp.asc)
                                .fetchOne(db)
                        {
                            // If the next job isn't currently running then delay it's start time
                            // until the 'nextRunTimestamp' unless it was manually triggered (in which
                            // case we want it to run immediately as some thread is likely waiting on
                            // it to return)
                            if !dependencies[singleton: .jobRunner].isCurrentlyRunning(existingJob) {
                                let jobWasManualTrigger: Bool = (existingJob.details
                                    .map { try? JSONDecoder(using: dependencies).decode(OptionalDetails.self, from: $0) }
                                    .map { $0.wasManualTrigger })
                                    .defaulting(to: false)
                                
                                try existingJob
                                    .with(nextRunTimestamp: (jobWasManualTrigger ? 0 : nextRunTimestamp))
                                    .upserted(db)
                            }
                            
                            // If there is another job then we should finish this one
                            shouldFinishCurrentJob = true
                            return job
                        }
                        
                        return try job
                            .with(nextRunTimestamp: nextRunTimestamp)
                            .upserted(db)
                    }
                    
                    ConfigurationSyncJob.startJobsWaitingOnConfigSync(swarmPublicKey, using: dependencies)
                    success((updatedJob ?? job), shouldFinishCurrentJob)
                }
            )
    }
    
    private static func startJobsWaitingOnConfigSync(
        _ swarmPublicKey: String,
        using dependencies: Dependencies
    ) {
        let targetJobs: [Job] = dependencies[singleton: .storage].read { db in
            return try Job
                .filter(Job.Columns.behaviour == Job.Behaviour.runOnceAfterConfigSyncIgnoringPermanentFailure)
                .filter(Job.Columns.threadId == swarmPublicKey)
                .fetchAll(db)
        }.defaulting(to: [])
        
        guard !targetJobs.isEmpty else { return }
        
        /// We use `upsert` because we want to avoid re-adding a job that happens to already be running or in the queue as these
        /// jobs should only run once
        dependencies[singleton: .storage].writeAsync { db in
            targetJobs.forEach { job in
                dependencies[singleton: .jobRunner].upsert(
                    db,
                    job: job,
                    canStartJob: true
                )
            }
        }
        Log.info(.cat, "Starting \(targetJobs.count) job(s) for \(swarmPublicKey) after successful config sync")
    }
}

// MARK: - ConfigurationSyncJob.OptionalDetails

extension ConfigurationSyncJob {
    public struct OptionalDetails: Codable {
        private enum CodingKeys: String, CodingKey {
            case wasManualTrigger
        }
        
        public let wasManualTrigger: Bool
    }
    
    /// This is additional data which can be passed to the `ConfigurationSyncJob` for a specific run but won't be persistent
    /// to disk for subsequent runs
    ///
    /// **Note:** If none of the values differ from the default then the `init` function will return `nil`
    public struct AdditionalTransientData {
        public let beforeSequenceRequests: [any ErasedPreparedRequest]
        public let afterSequenceRequests: [any ErasedPreparedRequest]
        public let requireAllBatchResponses: Bool
        public let requireAllRequestsSucceed: Bool
        
        init?(
            beforeSequenceRequests: [any ErasedPreparedRequest],
            afterSequenceRequests: [any ErasedPreparedRequest],
            requireAllBatchResponses: Bool,
            requireAllRequestsSucceed: Bool
        ) {
            guard
                !beforeSequenceRequests.isEmpty ||
                !afterSequenceRequests.isEmpty ||
                requireAllBatchResponses ||
                requireAllRequestsSucceed
            else { return nil }
            
            self.beforeSequenceRequests = beforeSequenceRequests
            self.afterSequenceRequests = afterSequenceRequests
            self.requireAllBatchResponses = requireAllBatchResponses
            self.requireAllRequestsSucceed = requireAllRequestsSucceed
        }
    }
}

// MARK: - Convenience

public extension ConfigurationSyncJob {
    static func enqueue(
        _ db: ObservingDatabase,
        swarmPublicKey: String,
        using dependencies: Dependencies
    ) {
        // Upsert a config sync job if needed
        dependencies[singleton: .jobRunner].upsert(
            db,
            job: ConfigurationSyncJob.createIfNeeded(db, swarmPublicKey: swarmPublicKey, using: dependencies),
            canStartJob: true
        )
    }
    
    @discardableResult static func createIfNeeded(
        _ db: ObservingDatabase,
        swarmPublicKey: String,
        using dependencies: Dependencies
    ) -> Job? {
        /// The ConfigurationSyncJob will automatically reschedule itself to run again after 3 seconds so if there is an existing
        /// job then there is no need to create another instance
        ///
        /// **Note:** Jobs with different `threadId` values can run concurrently
        guard
            dependencies[singleton: .jobRunner]
                .jobInfoFor(state: .running, variant: .configurationSync)
                .filter({ _, info in info.threadId == swarmPublicKey })
                .isEmpty,
            (try? Job
                .filter(Job.Columns.variant == Job.Variant.configurationSync)
                .filter(Job.Columns.threadId == swarmPublicKey)
                .isEmpty(db))
                .defaulting(to: false)
        else { return nil }
        
        // Otherwise create a new job
        return Job(
            variant: .configurationSync,
            behaviour: .recurring,
            threadId: swarmPublicKey
        )
    }
    
    /// Trigger the job emitting the result when completed
    ///
    /// **Note:** The `ConfigurationSyncJob` can only have a single instance running at a time, as a result this call may not
    /// resolve until after the current job has completed
    static func run(
        swarmPublicKey: String,
        beforeSequenceRequests: [any ErasedPreparedRequest] = [],
        afterSequenceRequests: [any ErasedPreparedRequest] = [],
        requireAllBatchResponses: Bool = false,
        requireAllRequestsSucceed: Bool = false,
        using dependencies: Dependencies
    ) -> AnyPublisher<Void, Error> {
        return Deferred {
            Future<Void, Error> { resolver in
                guard
                    let job: Job = Job(
                        variant: .configurationSync,
                        behaviour: .recurring,
                        threadId: swarmPublicKey,
                        details: OptionalDetails(wasManualTrigger: true),
                        transientData: AdditionalTransientData(
                            beforeSequenceRequests: beforeSequenceRequests,
                            afterSequenceRequests: afterSequenceRequests,
                            requireAllBatchResponses: requireAllBatchResponses,
                            requireAllRequestsSucceed: requireAllRequestsSucceed
                        )
                    )
                else { return resolver(Result.failure(NetworkError.parsingFailed)) }
                
                ConfigurationSyncJob.run(
                    job,
                    scheduler: DispatchQueue.global(qos: .userInitiated),
                    success: { _, _ in resolver(Result.success(())) },
                    failure: { _, error, _ in resolver(Result.failure(error)) },
                    deferred: { job in
                        dependencies[singleton: .jobRunner]
                            .afterJob(job)
                            .first()
                            .sinkUntilComplete(
                                receiveValue: { result in
                                    switch result {
                                        /// If it gets deferred a second time then we should probably just fail - no use waiting on something
                                        /// that may never run (also means we can avoid another potential defer loop)
                                        case .notFound, .deferred: resolver(Result.failure(NetworkError.unknown))
                                        case .failed(let error, _): resolver(Result.failure(error))
                                        case .succeeded: resolver(Result.success(()))
                                    }
                                }
                            )
                    },
                    using: dependencies
                )
            }
        }
        .eraseToAnyPublisher()
    }
}
