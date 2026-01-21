// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public struct JobState {
    public let queueId: JobQueue.JobQueueId
    public let job: Job
    public internal(set) var jobDependencies: [JobDependency]
    public internal(set) var status: Status
    public let resultStream: CurrentValueAsyncStream<JobRunner.JobResult?>
    
    public enum Status {
        case pending
        case running(task: Task<Void, Never>)
        case completed(result: JobRunner.JobResult)
        
        public var erasedStatus: JobRunner.JobStatus {
            switch self {
                case .pending: return .pending
                case .running: return .running
                case .completed: return .completed
            }
        }
    }
    
    public var isRunning: Bool {
        if case .running = status { return true }
        return false
    }
    
    public var isPending: Bool {
        if case .pending = status { return true }
        return false
    }
}
