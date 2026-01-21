// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

public struct JobDependency: Codable, Equatable, Hashable, FetchableRecord, PersistableRecord, TableRecord, ColumnExpressible {
    public static var databaseTableName: String { "jobDependency" }
    
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
        case jobId
        case variant
        case otherJobId
        case threadId
    }
    
    public enum Variant: Int, Codable, DatabaseValueConvertible, CaseIterable {
        /// The main job is dependant on another job being completed
        case job
        
        /// The main job is dependant on a successful config sync
        case configSync
    }
    
    /// The is the id of the main job
    public let jobId: Int64
    
    /// The is the id of the job that the main job is dependant on, used when
    ///
    /// **Note:** If this is `null` it means the dependant job has been deleted (but the dependency wasn't
    /// removed) this generally means a job has been directly deleted without it's dependencies getting cleaned
    /// up - If we find a job that has a dependency with no `otherJobId` then it's likely an invalid job and
    /// should be removed
    public let otherJobId: Int64?
    
    /// The is type of dependency
    public let variant: Variant
    
    /// The is the id for the conversation that is relevant to this dependency
    public let threadId: String?
    
    // MARK: - Initialization
    
    public init(
        jobId: Int64,
        variant: Variant,
        otherJobId: Int64?,
        threadId: String?
    ) {
        self.jobId = jobId
        self.variant = variant
        self.otherJobId = otherJobId
        self.threadId = threadId
    }
}
