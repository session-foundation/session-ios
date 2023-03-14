// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import PromiseKit
import SignalCoreKit
import SessionUtilitiesKit
import SessionSnodeKit

public enum GroupLeavingJob: JobExecutor {
    public static var maxFailureCount: Int = -1
    public static var requiresThreadId: Bool = true
    public static var requiresInteractionId: Bool = true
    
    public static func run(
        _ job: SessionUtilitiesKit.Job,
        queue: DispatchQueue,
        success: @escaping (SessionUtilitiesKit.Job, Bool) -> (),
        failure: @escaping (SessionUtilitiesKit.Job, Error?, Bool) -> (),
        deferred: @escaping (SessionUtilitiesKit.Job) -> ())
    {
        guard
            let detailsData: Data = job.details,
            let details: Details = try? JSONDecoder().decode(Details.self, from: detailsData)
        else {
            failure(job, JobRunnerError.missingRequiredDetails, false)
            return
        }
        
    }
}

// MARK: - GroupLeavingJob.Details

extension GroupLeavingJob {
    public struct Details: Codable {
        private enum CodingKeys: String, CodingKey {
            case infoMessageInteractionId
            case groupPublicKey
        }
        
        public let infoMessageInteractionId: Int64
        public let groupPublicKey: String
        
        // MARK: - Initialization
        
        public init(
            infoMessageInteractionId: Int64,
            groupPublicKey: String
        ) {
            self.infoMessageInteractionId = infoMessageInteractionId
            self.groupPublicKey = groupPublicKey
        }
        
        // MARK: - Codable
        
        public init(from decoder: Decoder) throws {
            let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
            
            self = Details(
                infoMessageInteractionId: try container.decode(Int64.self, forKey: .infoMessageInteractionId),
                groupPublicKey: try container.decode(String.self, forKey: .groupPublicKey)
            )
        }
        
        public func encode(to encoder: Encoder) throws {
            var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)

            try container.encode(infoMessageInteractionId, forKey: .infoMessageInteractionId)
            try container.encode(groupPublicKey, forKey: .groupPublicKey)
        }
    }
}

