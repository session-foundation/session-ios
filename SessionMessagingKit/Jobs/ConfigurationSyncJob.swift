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
            return .success
        }
        
        /// It's possible for multiple ConfigSyncJob's with the same target (user/group) to try to run at the same time since as soon as
        /// one is started we will enqueue a second one, in that case we should wait for the first job to complete before running the
        /// second in order to avoid pointlessly sending the same changes
        ///
        /// **Note:** The one exception to this rule is when the job has `AdditionalTransientData` because if we don't
        /// run it immediately then the `AdditionalTransientData` may not get run at all
        let maybeExistingJobState: JobState? = await dependencies[singleton: .jobRunner].firstJobMatching(
            filters: JobRunner.Filters(
                include: [
                    .variant(.configurationSync),
                    .status(.running)
                ],
                exclude: [
                    job.id.map { .jobId($0) },          /// Exclude this job
                    job.threadId.map { .threadId($0) }  /// Exclude jobs for different config stores
                ].compactMap { $0 }
            )
        )
        try Task.checkCancellation()
        
        if job.transientData == nil, let existingJobState: JobState = maybeExistingJobState {
            /// Wait for the existing job to complete before continuing
            Log.info(.cat, "For \(job.threadId ?? "UnknownId") waiting for completion of in-progress job")
            await dependencies[singleton: .jobRunner].result(for: existingJobState.job)
            try Task.checkCancellation()
            
            /// Also want to wait for `maxRunFrequency` to throttle the config sync runs
            try? await Task.sleep(for: .seconds(Int(maxRunFrequency)))
            try Task.checkCancellation()
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
            
            /// Now that we have completed a config sync we need the `JobRunner` to remove any dependencies waiting on it so
            /// those jobs can be started
            try await dependencies[singleton: .storage].writeAsync { db in
                dependencies[singleton: .jobRunner].removeJobDependency(
                    db,
                    variant: .configSync,
                    jobId: nil, /// The `configSync` dependency isn't on a specific job so don't pass the `jobId`
                    threadId: swarmPublicKey
                )
            }
            try Task.checkCancellation()
            
            return .success
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
            try Task.checkCancellation()
            
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
            try Task.checkCancellation()
            
            /// When we complete the `ConfigurationSync` job we want to immediately schedule another one with a
            /// `nextRunTimestamp` set to the `maxRunFrequency` value to throttle the config sync requests
            let nextRunTimestamp: TimeInterval = (dependencies.dateNow.timeIntervalSince1970 + maxRunFrequency)
            let otherPendingSyncJobs: [JobQueue.JobQueueId : JobState] = await dependencies[singleton: .jobRunner].jobsMatching(
                filters: JobRunner.Filters(
                    include: [
                        .variant(.configurationSync),
                        .threadId(swarmPublicKey),
                        .status(.pending)
                    ],
                    exclude: [job.id.map { .jobId($0) }].compactMap { $0 }
                )
            )
            try Task.checkCancellation()
            
            try await dependencies[singleton: .storage].writeAsync { db in
                /// Save the updated dumps to the database
                try configDumps.forEach { dump in
                    try dump.upsert(db)
                    
                    Task.detached(priority: .medium) { [extensionHelper = dependencies[singleton: .extensionHelper]] in
                        extensionHelper.replicate(dump: dump)
                    }
                }
                
                /// If there are additional `ConfigurationSync` jobs scheduled then we can just delay starting those by
                /// `maxRunFrequecy` (adding `index` as an additinoal offset to prevent multiple jobs from being kicked off at
                /// the same time)
                if !otherPendingSyncJobs.isEmpty {
                    try otherPendingSyncJobs.values.enumerated().forEach { index, jobState in
                        try dependencies[singleton: .jobRunner].update(
                            db,
                            job: jobState.job.with(
                                nextRunTimestamp: (nextRunTimestamp + TimeInterval(index))
                            )
                        )
                    }
                }
                else {
                    dependencies[singleton: .jobRunner].add(
                        db,
                        job: Job(
                            variant: .configurationSync,
                            nextRunTimestamp: nextRunTimestamp,
                            threadId: swarmPublicKey
                        )
                    )
                }
                
                /// Now that we have completed a config sync we need the `JobRunner` to remove any dependencies waiting on it so
                /// those jobs can be started
                dependencies[singleton: .jobRunner].removeJobDependency(
                    db,
                    variant: .configSync,
                    jobId: nil, /// The `configSync` dependency isn't on a specific job so don't pass the `jobId`
                    threadId: swarmPublicKey
                )
            }
            try Task.checkCancellation()
            
            Log.info(.cat, "For \(swarmPublicKey) completed")
            return .success
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
}

// MARK: - ConfigurationSyncJob.OptionalDetails

extension ConfigurationSyncJob {
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
        _ = try? await dependencies[singleton: .storage].writeAsync { db in
            dependencies[singleton: .jobRunner].add(
                db,
                job: Job(
                    variant: .configurationSync,
                    threadId: swarmPublicKey
                )
            )
        }
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
        let job: Job = try await dependencies[singleton: .storage].writeAsync { db in
            dependencies[singleton: .jobRunner].add(
                db,
                job: Job(
                    variant: .configurationSync,
                    threadId: swarmPublicKey,
                    transientData: AdditionalTransientData(
                        beforeSequenceRequests: beforeSequenceRequests,
                        afterSequenceRequests: afterSequenceRequests,
                        requireAllBatchResponses: requireAllBatchResponses,
                        requireAllRequestsSucceed: requireAllRequestsSucceed,
                        customAuthMethod: customAuthMethod
                    )
                )
            )
        } ?? { throw JobRunnerError.missingRequiredDetails }()
        
        /// Await the result of the job
        ///
        /// **Note:** We want to wait for the result of this specific job even though there may be another in progress because it's
        /// possible that this job was triggered after a config change and a currently running job was started before the change (if on is
        /// running then this job will wait for it to complete and complete instantly if there and no pending changes to be pushed)
        let result: JobRunner.JobResult = await dependencies[singleton: .jobRunner].result(for: job)
        
        /// Fail if we didn't get a successful result - no use waiting on something that may never run (also means we can avoid another
        /// potential defer loop)
        switch result {
            case .notFound, .deferred: throw JobRunnerError.missingRequiredDetails
            case .failed(let error, _): throw error
            case .succeeded: break
        }
    }
}
