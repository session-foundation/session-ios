// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionNetworkingKit
import SessionUtilitiesKit

// MARK: - Log.Category

private extension Log.Category {
    static let cat: Log.Category = .create("SendReadReceiptsJob", defaultLevel: .info)
}

// MARK: - SendReadReceiptsJob

public enum SendReadReceiptsJob: JobExecutor {
    public static let maxFailureCount: Int = -1
    public static let requiresThreadId: Bool = false
    public static let requiresInteractionId: Bool = false
    private static let maxRunFrequency: TimeInterval = 3
    
    public static func run(_ job: Job, using dependencies: Dependencies) async throws -> JobExecutionResult {
        guard
            let threadId: String = job.threadId,
            let detailsData: Data = job.details,
            let details: Details = try? JSONDecoder(using: dependencies).decode(Details.self, from: detailsData)
        else { throw JobRunnerError.missingRequiredDetails }
        
        /// If there are no `timestampMs` values then the job can just complete (next time something is marked as read we want to
        /// try and run immediately so don't scuedule another run in this case)
        guard !details.timestampMsValues.isEmpty else {
            return .success
        }
        
        /// Ensure there isn't already another `SendReadReceiptsJob` running (if there is then we should make this one dependant
        /// on that one and defer it)
        let maybeExistingJobState: JobState? = await dependencies[singleton: .jobRunner].firstJobMatching(
            filters:
                JobRunner.Filters(
                    include: [
                        .variant(.sendReadReceipts),
                        .threadId(threadId),
                        .status(.running)
                    ],
                    exclude: [job.id.map { .jobId($0) }].compactMap { $0 }   /// Exclude this job
                )
        )
        try Task.checkCancellation()
        
        if let existingJobState: JobState = maybeExistingJobState {
            if let jobId: Int64 = job.id, let otherJobId: Int64 = existingJobState.job.id {
                try? await dependencies[singleton: .storage].writeAsync { db in
                    try dependencies[singleton: .jobRunner].addJobDependency(
                        db,
                        forJobId: jobId,
                        variant: .job,
                        otherJobId: otherJobId,
                        threadId: nil
                    )
                }
            }
            
            /// Wait for the existing job to complete before continuing
            Log.info(.cat, "For \(job.threadId ?? "UnknownId") waiting for completion of in-progress job")
            await dependencies[singleton: .jobRunner].result(for: existingJobState.job)
            try Task.checkCancellation()
            
            /// Also want to wait for `maxRunFrequency` to throttle the config sync runs
            try? await Task.sleep(for: .seconds(Int(maxRunFrequency)))
            try Task.checkCancellation()
        }
        
        /// There is no other job running so we can run this one
        let authMethod: AuthenticationMethod = try Authentication.with(
            swarmPublicKey: threadId,
            using: dependencies
        )
        let request = try MessageSender.preparedSend(
            message: ReadReceipt(
                timestamps: details.timestampMsValues.map { UInt64($0) }
            ),
            to: details.destination,
            namespace: details.destination.defaultNamespace,
            interactionId: nil,
            attachments: nil,
            authMethod: authMethod,
            onEvent: MessageSender.standardEventHandling(using: dependencies),
            using: dependencies
        )
        
        // FIXME: Refactor this to use async/await
        let response = try await request.send(using: dependencies)
            .values
            .first(where: { _ in true })?.1 ?? { throw NetworkError.invalidResponse }()
        try Task.checkCancellation()
        
        /// When we complete the `SendReadReceiptsJob` we want to immediately schedule another one for the same thread
        /// but with a `nextRunTimestamp` set to the `maxRunFrequency` value to throttle the read receipt requests
        let nextRunTimestamp: TimeInterval = (dependencies.dateNow.timeIntervalSince1970 + maxRunFrequency)
        let otherPendingJobs: [JobQueue.JobQueueId : JobState] = await dependencies[singleton: .jobRunner].jobsMatching(
            filters: JobRunner.Filters(
                include: [
                    .variant(.sendReadReceipts),
                    .threadId(threadId),
                    .status(.pending)
                ],
                exclude: [job.id.map { .jobId($0) }].compactMap { $0 }
            )
        )
        try Task.checkCancellation()
        
        try await dependencies[singleton: .storage].writeAsync { db in
            /// If there are additional jobs scheduled then we can just delay starting those by `maxRunFrequecy` (adding `index`
            /// as an additinoal offset to prevent multiple jobs from being kicked off at the same time)
            if !otherPendingJobs.isEmpty {
                try otherPendingJobs.values.enumerated().forEach { index, jobState in
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
                        variant: .sendReadReceipts,
                        nextRunTimestamp: nextRunTimestamp,
                        threadId: threadId,
                        details: Details(
                            destination: details.destination,
                            timestampMsValues: []
                        )
                    )
                )
            }
        }
        
        return .success
    }
}


// MARK: - SendReadReceiptsJob.Details

extension SendReadReceiptsJob {
    public struct Details: Codable {
        public let destination: Message.Destination
        public let timestampMsValues: Set<Int64>
    }
}

// MARK: - Convenience

public extension SendReadReceiptsJob {
    /// This method upserts a `sendReadReceipts` job to include the timestamps for the specified `interactionIds`
    ///
    /// **Note:** This method assumes that the provided `interactionIds` are valid and won't filter out any invalid ids so
    /// ensure that is done correctly beforehand
    static func createOrUpdateIfNeeded(
        threadId: String,
        interactionIds: [Int64],
        using dependencies: Dependencies
    ) async {
        guard dependencies.mutate(cache: .libSession, { $0.get(.areReadReceiptsEnabled) }) else { return }
        guard !interactionIds.isEmpty else { return }
        
        /// Retrieve the `timestampMs` values for the specified interactions
        let timestampMsValues: [Int64] = ((try? await dependencies[singleton: .storage].readAsync { db in
            try Interaction
                .select(.timestampMs)
                .filter(interactionIds.contains(Interaction.Columns.id))
                .distinct()
                .asRequest(of: Int64.self)
                .fetchAll(db)
        }) ?? [])
        
        /// If there are no timestamp values then do nothing
        guard !timestampMsValues.isEmpty else { return }
        
        /// Try to get an existing job (if there is one that's not running)
        let maybePendingJob: JobState? = await dependencies[singleton: .jobRunner].firstJobMatching(
            filters: JobRunner.Filters(
                include: [
                    .variant(.sendReadReceipts),
                    .threadId(threadId),
                    .status(.pending)
                ]
            )
        )
        
        if
            let pendingJob: JobState = maybePendingJob,
            let existingDetailsData: Data = pendingJob.job.details,
            let existingDetails: Details = try? JSONDecoder(using: dependencies)
                .decode(Details.self, from: existingDetailsData),
            let updatedJob: Job = pendingJob.job.with(
                details: Details(
                    destination: existingDetails.destination,
                    timestampMsValues: existingDetails.timestampMsValues
                        .union(timestampMsValues)
                )
            )
        {
            _ = try? await dependencies[singleton: .storage].writeAsync { db in
                try dependencies[singleton: .jobRunner].update(
                    db,
                    job: updatedJob
                )
            }
        }
        else {
            /// Otherwise create a new job
            _ = try? await dependencies[singleton: .storage].writeAsync { db in
                dependencies[singleton: .jobRunner].add(
                    db,
                    job: Job(
                        variant: .sendReadReceipts,
                        threadId: threadId,
                        details: Details(
                            destination: .contact(publicKey: threadId),
                            timestampMsValues: timestampMsValues.asSet()
                        )
                    )
                )
            }
        }
    }
}
