// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public struct JobState {
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
}

public extension JobState {
    enum ExecutionState {
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
    }
    
    enum ExecutionPhase {
        case pending
        case running
        case completed
    }
    
    enum AttemptOutcome {
        case succeeded
        case failed(Error, isPermanent: Bool)
        case deferred
        case preempted
    }
}
