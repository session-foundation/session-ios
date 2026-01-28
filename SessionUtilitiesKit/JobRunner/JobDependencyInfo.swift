// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation

// MARK: - JobDependencyInfo

public enum JobDependencyInfo {
    case job(jobId: Int64, otherJobId: Int64)
    case timestamp(jobId: Int64, waitUntil: TimeInterval)
    case configSync(jobId: Int64, threadId: String)
    
    public var jobId: Int64 {
        switch self {
            case .job(let jobId, _): return jobId
            case .timestamp(let jobId, _): return jobId
            case .configSync(let jobId, _): return jobId
        }
    }
    
    internal func create() -> JobDependency {
        switch self {
            case .job(let jobId, let otherJobId):
                return JobDependency(
                    jobId: jobId,
                    variant: .job,
                    otherJobId: otherJobId
                )
                
            case .timestamp(let jobId, let timestamp):
                return JobDependency(
                    jobId: jobId,
                    variant: .timestamp,
                    timestamp: timestamp
                )
                
            case .configSync(let jobId, let threadId):
                return JobDependency(
                    jobId: jobId,
                    variant: .configSync,
                    threadId: threadId
                )
        }
    }
}

// MARK: - JobDependencyInitialInfo

public enum JobDependencyInitialInfo {
    case job(otherJobId: Int64)
    case timestamp(waitUntil: TimeInterval)
    case configSync(threadId: String)
    
    internal func create(with jobId: Int64) -> JobDependency {
        switch self {
            case .job(let otherJobId):
                return JobDependencyInfo.job(jobId: jobId, otherJobId: otherJobId).create()
                
            case .timestamp(let waitUntil):
                return JobDependencyInfo.timestamp(jobId: jobId, waitUntil: waitUntil).create()
            
            case .configSync(let threadId):
                return JobDependencyInfo.configSync(jobId: jobId, threadId: threadId).create()
        }
    }
}

// MARK: - JobDependencyRemovalInfo

public enum JobDependencyRemovalInfo {
    case job(Int64)
    case timestamp
    case configSync(String)
}
