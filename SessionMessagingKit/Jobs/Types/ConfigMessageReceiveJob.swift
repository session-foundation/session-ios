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
        success: @escaping (Job, Bool) -> (),
        failure: @escaping (Job, Error?, Bool) -> (),
        deferred: @escaping (Job) -> ()
    ) {
        guard
            let detailsData: Data = job.details,
            let details: Details = try? JSONDecoder().decode(Details.self, from: detailsData)
        else {
            failure(job, JobRunnerError.missingRequiredDetails, true)
            return
        }
        
        // Ensure no standard messages are sent through this job
        guard !details.messages.contains(where: { $0.variant != .sharedConfigMessage }) else {
            SNLog("[ConfigMessageReceiveJob] Standard messages incorrectly sent to the 'configMessageReceive' job")
            failure(job, MessageReceiverError.invalidMessage, true)
            return
        }
        
        var lastError: Error?
        let sharedConfigMessages: [SharedConfigMessage] = details.messages
            .compactMap { $0.message as? SharedConfigMessage }
        
        Storage.shared.write { db in
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
            case let error as MessageReceiverError where !error.isRetryable: failure(job, error, true)
            case .some(let error): failure(job, error, false)
            case .none: success(job, false)
        }
    }
}

// MARK: - ConfigMessageReceiveJob.Details

extension ConfigMessageReceiveJob {
    typealias Details = MessageReceiveJob.Details
}
