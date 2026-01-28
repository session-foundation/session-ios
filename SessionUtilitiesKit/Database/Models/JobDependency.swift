// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

/// This type should not be used directly outside of the `JobRunner` (it can result in unexpected behaviours) if it is
public struct JobDependency: Codable, Equatable, Hashable, FetchableRecord, PersistableRecord, TableRecord, ColumnExpressible {
    public static var databaseTableName: String { "jobDependency" }
    
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
        case jobId
        case variant
        case otherJobId
        case timestamp
        case threadId
    }
    
    public enum Variant: Int, Codable, DatabaseValueConvertible, CaseIterable {
        /// The main job is dependant on another job being completed
        case job
        
        /// The main job is dependant on a timestamp being in the past
        case timestamp
        
        /// The main job is dependant on a successful config sync
        case configSync
    }
    
    /// The is the id of the main job
    internal let jobId: Int64
    
    /// The is type of dependency
    internal let variant: Variant
    
    /// The is the id of the job that the main job is dependant on, used when
    ///
    /// **Note:** If this is `null` it means the dependant job has been deleted (but the dependency wasn't
    /// removed) this generally means a job has been directly deleted without it's dependencies getting cleaned
    /// up - If we find a job that has a dependency with no `otherJobId` then it's likely an invalid job and
    /// should be removed
    internal let otherJobId: Int64?
    
    /// The is the timestamp that needs to be in the past before the main job can run
    internal let timestamp: TimeInterval?
    
    /// The is the id for the conversation that is relevant to this dependency
    internal let threadId: String?
    
    // MARK: - Initialization
    
    internal init(
        jobId: Int64,
        variant: Variant,
        otherJobId: Int64? = nil,
        timestamp: TimeInterval? = nil,
        threadId: String? = nil
    ) {
        self.jobId = jobId
        self.variant = variant
        self.otherJobId = otherJobId
        self.timestamp = timestamp
        self.threadId = threadId
    }
}

// MARK: - Convenience

internal extension JobDependency {
    func existsInDatabase(_ db: ObservingDatabase) -> Bool {
        var query: QueryInterfaceRequest<JobDependency> = JobDependency
            .filter(JobDependency.Columns.variant == variant)

        if let otherJobId: Int64 = otherJobId {
            query = query.filter(JobDependency.Columns.otherJobId == otherJobId)
        }

        if let timestamp: TimeInterval = timestamp {
            query = query.filter(JobDependency.Columns.timestamp == timestamp)
        }

        if let threadId: String = threadId {
            query = query.filter(JobDependency.Columns.threadId == threadId)
        }
        
        return query.isNotEmpty(db)
    }
}
