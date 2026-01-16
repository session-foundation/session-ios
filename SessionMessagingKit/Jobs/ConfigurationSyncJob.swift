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
    
    public static func run(_ job: Job, using dependencies: Dependencies) async throws -> JobExecutionResult {
        guard !dependencies[cache: .libSession].isEmpty else {
            return .success(job, stop: true)
        }
        
        /// It's possible for multiple ConfigSyncJob's with the same target (user/group) to try to run at the same time since as soon as
        /// one is started we will enqueue a second one, rather than adding dependencies between the jobs we just continue to defer
        /// the subsequent job while the first one is running in order to prevent multiple configurationSync jobs with the same target
        /// from running at the same time
        ///
        /// **Note:** The one exception to this rule is when the job has `AdditionalTransientData` because if we don't
        /// run it immediately then the `AdditionalTransientData` may not get run at all
        let hasExistingJob: Bool = await dependencies[singleton: .jobRunner]
            .jobInfoFor(
                state: .running,
                filters: JobRunner.Filters(
                    include: [.variant(.configurationSync)],
                    exclude: [
                        job.id.map { .jobId($0) },          /// Exclude this job
                        job.threadId.map { .threadId($0) }  /// Exclude jobs for different config stores
                    ].compactMap { $0 }
                )
            )
            .isEmpty
        
        guard job.transientData != nil || hasExistingJob else {
            /// Defer the job to run `maxRunFrequency` from when this one ran (if we don't it'll try start it again immediately which
            /// is pointless)
            let updatedJob: Job? = dependencies[singleton: .storage].write { db in
                try job
                    .with(nextRunTimestamp: dependencies.dateNow.timeIntervalSince1970 + maxRunFrequency)
                    .upserted(db)
            }
            
            Log.info(.cat, "For \(job.threadId ?? "UnknownId") deferred due to in progress job")
            return .deferred(updatedJob ?? job)
        }
        
        /// If we don't have a userKeyPair yet then there is no need to sync the configuration as the user doesn't exist yet (this will get
        /// triggered on the first launch of a fresh install due to the migrations getting run)
        guard
            let swarmPublicKey: String = job.threadId,
            let pendingPushes: LibSession.PendingPushes = try? dependencies.mutate(cache: .libSession, {
                try $0.pendingPushes(swarmPublicKey: swarmPublicKey)
            })
        else {
            Log.info(.cat, "For \(job.threadId ?? "UnknownId") failed due to invalid data")
            throw StorageError.generic
        }
        
        /// If there is no `pushData` or additional sequence requests then the job can just complete (next time something is updated
        /// we want to try and run immediately so don't scuedule another run in this case)
        guard
            !pendingPushes.pushData.isEmpty ||
            job.transientData != nil
        else {
            Log.info(.cat, "For \(swarmPublicKey) completed with no pending changes")
            ConfigurationSyncJob.startJobsWaitingOnConfigSync(swarmPublicKey, using: dependencies)
            return .success(job, stop: true)
        }
        
        let jobStartTimestamp: TimeInterval = dependencies.dateNow.timeIntervalSince1970
        let messageSendTimestamp: Int64 = dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
        let additionalTransientData: AdditionalTransientData? = (job.transientData as? AdditionalTransientData)
        Log.info(.cat, "For \(swarmPublicKey) started with changes: \(pendingPushes.pushData.count), old hashes: \(pendingPushes.obsoleteHashes.count)")
        
        let authMethod: AuthenticationMethod = try (
            additionalTransientData?.customAuthMethod ??
            Authentication.with(
                swarmPublicKey: swarmPublicKey,
                using: dependencies
            )
        )
        
        let request: Network.PreparedRequest<Network.BatchResponse> = try Network.SnodeAPI.preparedSequence(
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
        )
        
        do {
            // FIXME: Refactor this to use async/await
            let response: Network.BatchResponse = try await request
                .send(using: dependencies)
                .values
                .first(where: { _ in true })?.1 ?? { throw NetworkError.invalidResponse }()
            
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
            let configDumps: [ConfigDump] = try dependencies.mutate(cache: .libSession) { cache in
                try cache.createDumpMarkingAsPushed(
                    data: results,
                    sentTimestamp: messageSendTimestamp,
                    swarmPublicKey: swarmPublicKey
                )
            }
            
            /// Lastly we need to save the updated dumps to the database
            let currentlyRunningJobs: [JobRunner.JobInfo] = await Array(dependencies[singleton: .jobRunner]
                .jobInfoFor(
                    state: .running,
                    filters: ConfigurationSyncJob.filters(
                        swarmPublicKey: swarmPublicKey,
                        whenRunning: job
                    )
                )
                .values)
            let updatedJob: Job? = try await dependencies[singleton: .storage].writeAsync { db in
                /// Save the updated dumps to the database
                try configDumps.forEach { dump in
                    try dump.upsert(db)
                    
                    Task.detached(priority: .medium) { [extensionHelper = dependencies[singleton: .extensionHelper]] in
                        extensionHelper.replicate(dump: dump)
                    }
                }
                
                /// When we complete the `ConfigurationSync` job we want to immediately schedule another one with a
                ///  `nextRunTimestamp` set to the `maxRunFrequency` value to throttle the config sync requests
                let nextRunTimestamp: TimeInterval = (jobStartTimestamp + maxRunFrequency)
                
                /// If another `ConfigurationSync` job was scheduled then we can just update that one to run at `nextRunTimestamp`
                /// and make the current job stop
                if
                    let existingJobInfo: JobRunner.JobInfo = currentlyRunningJobs
                        .sorted(by: { lhs, rhs in lhs.nextRunTimestamp < rhs.nextRunTimestamp })
                        .first,
                    let jobId: Int64 = existingJobInfo.id,
                    let existingJob: Job = try? Job.fetchOne(db, id: jobId)
                {
                    /// If the next job isn't currently running then delay it's start time until the `nextRunTimestamp` unless
                    /// it was manually triggered (in which case we want it to run immediately as some thread is likely waiting on
                    /// it to return)
                    let jobWasManualTrigger: Bool = (existingJob.details
                        .map { try? JSONDecoder(using: dependencies).decode(OptionalDetails.self, from: $0) }
                        .map { $0.wasManualTrigger })
                        .defaulting(to: false)
                    
                    try existingJob
                        .with(nextRunTimestamp: (jobWasManualTrigger ? 0 : nextRunTimestamp))
                        .upserted(db)
                    
                    return nil
                }
                
                return try job
                    .with(nextRunTimestamp: nextRunTimestamp)
                    .upserted(db)
            }
            
            /// If we returned no `updatedJob` above then we want to stop the current job (because there is an existing job
            /// that we've already rescueduled)
            ConfigurationSyncJob.startJobsWaitingOnConfigSync(swarmPublicKey, using: dependencies)
            Log.info(.cat, "For \(swarmPublicKey) completed")
            return .success((updatedJob ?? job), stop: (updatedJob == nil))
        }
        catch {
            Log.error(.cat, "For \(swarmPublicKey) failed due to error: \(error)")
            
            /// If the failure is due to being offline then we should automatically retry if the connection is re-established
            // FIXME: Refactor this to use async/await
            let status: NetworkStatus? = await dependencies[cache: .libSessionNetwork].networkStatus
                .values
                .first(where: { _ in true })
            
            switch status {
                /// If we are currently connected then use the standard retry behaviour
                case .connected: throw error
                    
                /// If not then spin up a task to reschedule the config sync if we re-establish the connection and permanently
                /// fail this job
                default:
                    Task.detached(priority: .background) { [dependencies] in
                        // FIXME: Refactor this to use async/await
                        _ = await dependencies[cache: .libSessionNetwork].networkStatus
                            .values
                            .first(where: { $0 == .connected })
                        await ConfigurationSyncJob.enqueue(
                            swarmPublicKey: swarmPublicKey,
                            using: dependencies
                        )
                    }
                    
                    throw JobRunnerError.permanentFailure(error)
            }
        }
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
        public let customAuthMethod: AuthenticationMethod?
        
        init?(
            beforeSequenceRequests: [any ErasedPreparedRequest],
            afterSequenceRequests: [any ErasedPreparedRequest],
            requireAllBatchResponses: Bool,
            requireAllRequestsSucceed: Bool,
            customAuthMethod: AuthenticationMethod?
        ) {
            guard
                !beforeSequenceRequests.isEmpty ||
                !afterSequenceRequests.isEmpty ||
                requireAllBatchResponses ||
                requireAllRequestsSucceed ||
                customAuthMethod != nil
            else { return nil }
            
            self.beforeSequenceRequests = beforeSequenceRequests
            self.afterSequenceRequests = afterSequenceRequests
            self.requireAllBatchResponses = requireAllBatchResponses
            self.requireAllRequestsSucceed = requireAllRequestsSucceed
            self.customAuthMethod = customAuthMethod
        }
    }
}

// MARK: - Convenience

public extension ConfigurationSyncJob {
    static func enqueue(
        swarmPublicKey: String,
        using dependencies: Dependencies
    ) async {
        /// Upsert a config sync job if needed
        guard let job: Job = await ConfigurationSyncJob.createIfNeeded(swarmPublicKey: swarmPublicKey, using: dependencies) else {
            return
        }
        
        _ = try? await dependencies[singleton: .storage].writeAsync { db in
            dependencies[singleton: .jobRunner].upsert(db, job: job, canStartJob: true)
        }
    }
    
    @discardableResult static func createIfNeeded(
        swarmPublicKey: String,
        using dependencies: Dependencies
    ) async -> Job? {
        /// The ConfigurationSyncJob will automatically reschedule itself to run again after 3 seconds so if there is an existing
        /// job then there is no need to create another instance
        ///
        /// **Note:** Jobs with different `threadId` values can run concurrently
        guard
            await dependencies[singleton: .jobRunner]
                .jobInfoFor(
                    state: .running,
                    filters: ConfigurationSyncJob.filters(swarmPublicKey: swarmPublicKey)
                )
                .isEmpty,
            (try? await dependencies[singleton: .storage].readAsync(value: { db -> Bool in
                try Job
                    .filter(Job.Columns.variant == Job.Variant.configurationSync)
                    .filter(Job.Columns.threadId == swarmPublicKey)
                    .isEmpty(db)
            })) == true
        else { return nil }
        
        /// Otherwise create a new job
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
        customAuthMethod: AuthenticationMethod? = nil,
        using dependencies: Dependencies
    ) async throws {
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
                    requireAllRequestsSucceed: requireAllRequestsSucceed,
                    customAuthMethod: customAuthMethod
                )
            )
        else { throw JobRunnerError.missingRequiredDetails }
        
        let result: JobExecutionResult = try await ConfigurationSyncJob.run(job, using: dependencies)
        
        /// If the job was deferred it was most likely due to another `SyncPushTokens` job in progress so we should wait
        /// for the other job to finish and try again
        switch result {
            case .success: return
            case .deferred: break
        }
        
        let runningJobs: [Int64: JobRunner.JobInfo] = await dependencies[singleton: .jobRunner]
            .jobInfoFor(
                state: .running,
                filters: ConfigurationSyncJob.filters(swarmPublicKey: swarmPublicKey, whenRunning: job)
            )
        
        /// If we couldn't find a running job then fail (something else went wrong)
        guard !runningJobs.isEmpty else { throw JobRunnerError.missingRequiredDetails }
        
        let otherJobResult: JobRunner.JobResult = await dependencies[singleton: .jobRunner].awaitResult(
            forFirstJobMatching: ConfigurationSyncJob.filters(swarmPublicKey: swarmPublicKey, whenRunning: job),
            in: .running
        )
        
        /// If it gets deferred a second time then we should probably just fail - no use waiting on something
        /// that may never run (also means we can avoid another potential defer loop)
        switch otherJobResult {
            case .notFound, .deferred: throw JobRunnerError.missingRequiredDetails
            case .failed(let error, _): throw error
            case .succeeded: break
        }
    }
    
    private static func filters(swarmPublicKey: String, whenRunning job: Job? = nil) -> JobRunner.Filters {
        return JobRunner.Filters(
            include: [
                .variant(.configurationSync),
                .threadId(swarmPublicKey)
            ],
            exclude: [job?.id.map { .jobId($0) }].compactMap { $0 }   /// Exclude running job
        )
    }
}
