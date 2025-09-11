// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

public struct JobDependencies: Codable, Equatable, Hashable, FetchableRecord, PersistableRecord, TableRecord, ColumnExpressible {
    public static var databaseTableName: String { "jobDependencies" }
    
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
        case jobId
        case dependantId
    }
    
    /// The is the id of the main job
    public let jobId: Int64
    
    /// The is the id of the job that the main job is dependant on
    ///
    /// **Note:** If this is `null` it means the dependant job has been deleted (but the dependency wasn't
    /// removed) this generally means a job has been directly deleted without it's dependencies getting cleaned
    /// up - If we find a job that has a dependency with no `dependantId` then it's likely an invalid job and
    /// should be removed
    public let dependantId: Int64?
    
    // MARK: - Initialization
    
    public init(
        jobId: Int64,
        dependantId: Int64
    ) {
        self.jobId = jobId
        self.dependantId = dependantId
    }
}
