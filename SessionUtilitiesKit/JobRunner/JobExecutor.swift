// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public protocol JobExecutor {
    /// The maximum number of times the job can fail before it fails permanently
    ///
    /// **Note:** A value of `-1` means it will retry indefinitely
    static var maxFailureCount: Int { get }
    static var requiresThreadId: Bool { get }
    static var requiresInteractionId: Bool { get }
    
    /// A flag indicating whether this job can be cancelled to make space for a higher priority job
    static var canBePreempted: Bool { get }
    
    /// This method contains the logic needed to complete a job
    ///
    /// - Parameters:
    ///   - job: The job which is being run
    ///   - dependencies: The application's dependencies
    /// - Returns: A `JobExecutionResult` indicating success or deferral
    /// - Throws: An error if the job failed, the error should conform to `JobError` to indicate if the failure is permanent
    static func run(_ job: Job, using dependencies: Dependencies) async throws -> JobExecutionResult
}

public extension JobExecutor {
    static var canBePreempted: Bool { false }
}

// MARK: - JobExecutionResult

public enum JobExecutionResult {
    /// The job completed successfully
    case success

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

