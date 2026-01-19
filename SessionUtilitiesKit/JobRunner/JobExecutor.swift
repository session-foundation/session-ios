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

    /// Optional function which indicates whether a job can be started
    static func canStart(job: Job, using dependencies: Dependencies) async -> Bool
    
    /// This method contains the logic needed to complete a job
    ///
    /// - Parameters:
    ///   - job: The job which is being run
    ///   - dependencies: The application's dependencies
    /// - Returns: A `JobExecutionResult` indicating success or deferral
    /// - Throws: An error if the job failed, the error should conform to `JobError` to indicate if the failure is permanent
    static func run(_ job: Job, using dependencies: Dependencies) async throws -> JobExecutionResult
    
    /// Determines if `thisJob` should be prioritized over `otherJob`.
    ///
    /// This allows for granular, cross-variant prioritization logic (e.g. An `AttachmentUploadJob` can be prioritised over an
    /// `AttachmentDownloadJob`)
    /// - Returns: `true` if `thisJob` is strictly higher priority than `otherJob`, return `false` if equal or lower
    static func isHigherPriority(thisJob: Job, than otherJob: Job, context: JobPriorityContext) -> Bool
}

public extension JobExecutor {
    static var canBePreempted: Bool { false }
    
    static func canStart(job: Job, using dependencies: Dependencies) async -> Bool { true }
    static func isHigherPriority(thisJob: Job, than otherJob: Job, context: JobPriorityContext) -> Bool { false }
}

// MARK: - JobExecutionResult

public enum JobExecutionResult {
    /// The job completed successfully
    /// - `updatedJob`: The job instance, potentially with updated details or state for recurring jobs
    case success(_ updatedJob: Job)

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

