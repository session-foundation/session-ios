// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

public enum ConfigMessageReceiveJob: JobExecutor {
    public static var maxFailureCount: Int = 0
    public static var requiresThreadId: Bool = true
    public static let requiresInteractionId: Bool = false
    
    public static func run(
        _ job: Job,
        queue: DispatchQueue,
        success: @escaping (Job, Bool, Dependencies) -> (),
        failure: @escaping (Job, Error?, Bool, Dependencies) -> (),
        deferred: @escaping (Job, Dependencies) -> (),
        using dependencies: Dependencies = Dependencies()
    ) {
        /// When the `configMessageReceive` job fails we want to unblock any `messageReceive` jobs it was blocking
        /// to ensure the user isn't losing any messages - this generally _shouldn't_ happen but if it does then having a temporary
        /// "outdated" state due to standard messages which would have been invalidated by a config change incorrectly being
        /// processed is less severe then dropping a bunch on messages just because they were processed in the same poll as
        /// invalid config messages
        let removeDependencyOnMessageReceiveJobs: () -> () = {
            guard let jobId: Int64 = job.id else { return }
            
            dependencies.storage.write { db in
                try JobDependencies
                    .filter(JobDependencies.Columns.dependantId == jobId)
                    .joining(
                        required: JobDependencies.job
                            .filter(Job.Columns.variant == Job.Variant.messageReceive)
                    )
                    .deleteAll(db)
            }
        }
        
        guard
            let detailsData: Data = job.details,
            let details: Details = try? JSONDecoder().decode(Details.self, from: detailsData)
        else {
            removeDependencyOnMessageReceiveJobs()
            return failure(job, JobRunnerError.missingRequiredDetails, true, dependencies)
        }

        // Ensure no standard messages are sent through this job
        guard !details.messages.contains(where: { $0.variant != .sharedConfigMessage }) else {
            SNLog("[ConfigMessageReceiveJob] Standard messages incorrectly sent to the 'configMessageReceive' job")
            removeDependencyOnMessageReceiveJobs()
            return failure(job, MessageReceiverError.invalidMessage, true, dependencies)
        }
        
        var lastError: Error?
        let sharedConfigMessages: [SharedConfigMessage] = details.messages
            .compactMap { $0.message as? SharedConfigMessage }
        
        dependencies.storage.write { db in
            // Send any SharedConfigMessages to the SessionUtil to handle it
            do {
                try SessionUtil.handleConfigMessages(
                    db,
                    messages: sharedConfigMessages,
                    publicKey: (job.threadId ?? "")
                )
            }
            catch { lastError = error }
        }
        
        // Handle the result
        switch lastError {
            case .some(let error):
                removeDependencyOnMessageReceiveJobs()
                failure(job, error, true, dependencies)

            case .none: success(job, false, dependencies)
        }
    }
}

// MARK: - ConfigMessageReceiveJob.Details

extension ConfigMessageReceiveJob {
    typealias Details = MessageReceiveJob.Details
}
