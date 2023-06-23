// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SignalCoreKit
import SessionUtilitiesKit

public enum GetSnodePoolJob: JobExecutor {
    public static let maxFailureCount: Int = -1
    public static let requiresThreadId: Bool = false
    public static let requiresInteractionId: Bool = false
    
    public static func run(
        _ job: Job,
        queue: DispatchQueue,
        success: @escaping (Job, Bool) -> (),
        failure: @escaping (Job, Error?, Bool) -> (),
        deferred: @escaping (Job) -> ()
    ) {
        // If we already have cached Snodes then we still want to trigger the 'SnodeAPI.getSnodePool'
        // but we want to succeed this job immediately (since it's marked as blocking), this allows us
        // to block if we have no Snode pool and prevent other jobs from failing but avoids having to
        // wait if we already have a potentially valid snode pool
        guard !SnodeAPI.hasCachedSnodesInclusingExpired() else {
            SNLog("[GetSnodePoolJob] Has valid cached pool, running async instead")
            SnodeAPI
                .getSnodePool()
                .subscribe(on: DispatchQueue.global(qos: .default))
                .sinkUntilComplete()
            success(job, false)
            return
        }
        
        // If we don't have the snode pool cached then we should also try to build the path (this will
        // speed up the onboarding process for new users because it can run before the user is created)
        SnodeAPI.getSnodePool()
            .flatMap { _ in OnionRequestAPI.getPath(excluding: nil) }
            .subscribe(on: queue)
            .receive(on: queue)
            .sinkUntilComplete(
                receiveCompletion: { result in
                    switch result {
                        case .finished:
                            SNLog("[GetSnodePoolJob] Completed")
                            success(job, false)
                            
                        case .failure(let error):
                            SNLog("[GetSnodePoolJob] Failed due to error: \(error)")
                            failure(job, error, false)
                    }
                }
            )
    }
    
    public static func run() {
        GetSnodePoolJob.run(
            Job(variant: .getSnodePool),
            queue: .global(qos: .background),
            success: { _, _ in },
            failure: { _, _, _ in },
            deferred: { _ in }
        )
    }
}
