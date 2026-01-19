// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionNetworkingKit
import SessionUtilitiesKit

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
        
        /// If there are no timestampMs values then the job can just complete (next time something is marked as read we want to try
        /// and run immediately so don't scuedule another run in this case)
        guard !details.timestampMsValues.isEmpty else {
            return .success(job, stop: true)
        }
        
        /// Ensure there isn't already another `SendReadReceiptsJob` running (if there is then we should make this one dependant
        /// on that one and defer it)
        let filters: JobRunner.Filters = SendReadReceiptsJob.filters(threadId: threadId, whenRunning: job)
        
        if
            let otherJob: Job = await dependencies[singleton: .jobRunner].firstJobMatching(
                filters: filters.including(.status(.running))
            ),
            let jobId: Int64 = job.id,
            let otherJobId: Int64 = otherJob.id
        {
            try await dependencies[singleton: .storage].writeAsync { db in
                dependencies[singleton: .jobRunner].addDependency(db, forJobId: jobId, on: otherJobId)
            }
            
            return .deferred(job)
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
        
        /// When we complete the `SendReadReceiptsJob` we want to immediately schedule another one for the same thread
        /// but with a `nextRunTimestamp` set to the `maxRunFrequency` value to throttle the read receipt requests
        var shouldFinishCurrentJob: Bool = false
        let nextRunTimestamp: TimeInterval = (dependencies.dateNow.timeIntervalSince1970 + maxRunFrequency)
        
        /// If another `sendReadReceipts` job was scheduled then update that one to run at `nextRunTimestamp`
        /// and make the current job stop
        var targetJob: Job = job
        
        if let otherJob: Job = await dependencies[singleton: .jobRunner].firstJobMatching(filters: filters) {
            try await dependencies[singleton: .storage].writeAsync { db in
                try dependencies[singleton: .jobRunner].update(
                    db,
                    job: otherJob.with(nextRunTimestamp: nextRunTimestamp)
                )
            }
        }
        
        let updatedJob: Job = targetJob
            .with(details: Details(destination: details.destination, timestampMsValues: []))
            .defaulting(to: targetJob)
            .with(nextRunTimestamp: nextRunTimestamp)
        
        return .success(updatedJob, stop: shouldFinishCurrentJob)
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
    private static func filters(threadId: String, whenRunning job: Job? = nil) -> JobRunner.Filters {
        return JobRunner.Filters(
            include: [
                .variant(.sendReadReceipts),
                .threadId(threadId)
            ],
            exclude: [job?.id.map { .jobId($0) }].compactMap { $0 }   /// Exclude running job
        )
    }
    
    /// This method upserts a 'sendReadReceipts' job to include the timestamps for the specified `interactionIds`
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
        
        /// Retrieve the timestampMs values for the specified interactions
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
        let filters: JobRunner.Filters = SendReadReceiptsJob.filters(threadId: threadId)
        
        if
            let existingJob: Job = await dependencies[singleton: .jobRunner].firstJobMatching(
                filters: filters.excluding(.status(.running))
            ),
            let existingDetailsData: Data = existingJob.details,
            let existingDetails: Details = try? JSONDecoder(using: dependencies)
                .decode(Details.self, from: existingDetailsData),
            let updatedJob: Job = existingJob.with(
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
        
        /// Otherwise create a new job
        _ = try? await dependencies[singleton: .storage].writeAsync { db in
            dependencies[singleton: .jobRunner].add(
                db,
                job: Job(
                    variant: .sendReadReceipts,
                    behaviour: .recurring,
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
