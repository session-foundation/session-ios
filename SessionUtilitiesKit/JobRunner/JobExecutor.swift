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
    
    /// A flag indicatoring whether this can should only be run while the app is in the foreground
    static var requiresForeground: Bool { get }
    
    /// An optional function that indicates whether a job can be started while other jobs of the same `Job.Variant` are already
    /// running. This can be used to add special concurrency requirements for to a job (eg. one job per `threadId`)
    ///
    /// - Parameters:
    ///   - jobState: The job we want to start
    ///   - runningJobs: Any currently running jobs of the same `Job.Variant`
    ///   - dependencies: The application's dependencies
    /// - Returns: A flag indicating whether the job canb e started
    ///
    /// **Note:** Adding a default implementation for this in the extension below seems to cause memory corruption when trying to
    /// call `run`, so we need to explicitly implement it
    static func canStart(
        jobState: JobState,
        alongside runningJobs: [JobState],
        using dependencies: Dependencies
    ) -> Bool
    
    /// This function contains the logic needed to complete a job
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
    static var requiresForeground: Bool { false }
}

// MARK: - JobExecutionResult

public enum JobExecutionResult {
    /// The job completed successfully
    case success

    /// The job couldn't be completed and should be run again later
    /// - `nextRunTimestamp`: The timestamp when the job should be run again (if an explicit timestamp isn't provided then it will
    /// be set to 1 second in the future
    case deferred(nextRunTimestamp: TimeInterval? = nil)
    
    // MARK: - Convenience
    
    public static let deferred: JobExecutionResult = .deferred(nextRunTimestamp: nil)
}

// MARK: - JobPriorityContext

public struct JobPriorityContext: Sendable, Equatable {
    public static let empty: JobPriorityContext = JobPriorityContext(activeThreadId: nil)
    
    public let activeThreadId: String?
    
    public init(activeThreadId: String?) {
        self.activeThreadId = activeThreadId
    }
}
