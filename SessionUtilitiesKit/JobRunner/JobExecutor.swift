// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public protocol JobExecutor {
    /// The maximum number of times the job can fail before it fails permanently
    ///
    /// **Note:** A value of `-1` means it will retry indefinitely
    static var maxFailureCount: Int { get }
    static var requiresThreadId: Bool { get }
    static var requiresInteractionId: Bool { get }

    /// This method contains the logic needed to complete a job
    ///
    /// - Parameters:
    ///   - job: The job which is being run
    ///   - dependencies: The application's dependencies
    /// - Returns: A `JobExecutionResult` indicating success or deferral
    /// - Throws: An error if the job failed, the error should conform to `JobError` to indicate if the failure is permanent
    static func run(_ job: Job, using dependencies: Dependencies) async throws -> JobExecutionResult
}

// MARK: - JobExecutionResult

public enum JobExecutionResult {
    /// The job completed successfully
    /// - `updatedJob`: The job instance, potentially with updated details or state for recurring jobs
    /// - `stop`: A flag indicating if a recurring job should be permanently stopped and deleted
    case success(_ updatedJob: Job, stop: Bool)

    /// The job couldn't be completed and should be run again later
    /// - `updatedJob`: The job instance, can include changes like an updated `nextRunTimestamp` value to indicate when the
    /// job should be run again
    case deferred(_ updatedJob: Job)
    
    var publicResult: JobRunner.JobResult {
        switch self {
            case .success: return .succeeded
            case .deferred: return .deferred
        }
    }
}

