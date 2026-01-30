// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public struct JobState: Equatable {
    public let queueId: JobQueue.JobQueueId
    public internal(set) var job: Job
    internal var jobDependencies: [JobDependency]
    public internal(set) var executionState: ExecutionState
    internal let resultStream: CurrentValueAsyncStream<JobRunner.JobResult?>
    
    public var isRunning: Bool {
        if case .running = executionState { return true }
        return false
    }
    
    public var isPending: Bool {
        if case .pending = executionState { return true }
        return false
    }
    
    // MARK: - Equatable
    
    public static func == (lhs: JobState, rhs: JobState) -> Bool {
        return (
            lhs.queueId == rhs.queueId &&
            lhs.job == rhs.job &&
            lhs.jobDependencies == rhs.jobDependencies &&
            lhs.executionState == rhs.executionState
        )
    }
}

public extension JobState {
    enum ExecutionState: Equatable {
        case pending(lastAttempt: AttemptOutcome?)
        case running(task: Task<Void, Never>)
        case completed(result: JobRunner.JobResult)
        
        static let pending: ExecutionState = .pending(lastAttempt: nil)
        
        public var phase: ExecutionPhase {
            switch self {
                case .pending: return .pending
                case .running: return .running
                case .completed: return .completed
            }
        }
        
        // MARK: - Equatable
        
        public static func == (lhs: ExecutionState, rhs: ExecutionState) -> Bool {
            switch (lhs, rhs) {
                case (.pending(let lhsLastAttempt), .pending(let rhsLastAttempt)):
                    return (lhsLastAttempt == rhsLastAttempt)
                    
                case (.running, .running): return true
                    
                case (.completed(let lhsResult), .completed(let rhsResult)):
                    return (lhsResult == rhsResult)
                    
                default: return false
            }
        }
    }
    
    enum ExecutionPhase {
        case pending
        case running
        case completed
    }
    
    enum AttemptOutcome: Equatable {
        case succeeded
        case failed(Error, isPermanent: Bool)
        case deferred
        case preempted
        
        // MARK: - Equatable
        
        public static func == (lhs: AttemptOutcome, rhs: AttemptOutcome) -> Bool {
            switch (lhs, rhs) {
                case (.succeeded, .succeeded): return true
                case (.deferred, .deferred): return true
                case (.preempted, .preempted): return true
                    
                case (.failed(let lhsError, let lhsPermanent), .failed(let rhsError, let rhsPermanent)): return (
                        // Not a perfect solution but should be good enough
                        "\(lhsError)" == "\(rhsError)" &&
                        lhsPermanent == rhsPermanent
                    )
                    
                default: return false
            }
        }
    }
}
