// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionSnodeKit
import SessionUtilitiesKit

// MARK: - Log.Category

private extension Log.Category {
    static let cat: Log.Category = .create("CheckForAppUpdatesJob", defaultLevel: .info)
}

// MARK: - CheckForAppUpdatesJob

public enum CheckForAppUpdatesJob: JobExecutor {
    private static let updateCheckFrequency: TimeInterval = (4 * 60 * 60)  // Max every 4 hours
    public static var maxFailureCount: Int = -1
    public static var requiresThreadId: Bool = false
    public static let requiresInteractionId: Bool = false
    
    public static func run<S: Scheduler>(
        _ job: Job,
        scheduler: S,
        success: @escaping (Job, Bool) -> Void,
        failure: @escaping (Job, Error, Bool) -> Void,
        deferred: @escaping (Job) -> Void,
        using dependencies: Dependencies
    ) {
        // Just defer the update check when running tests or in the simulator
#if targetEnvironment(simulator)
        let shouldCheckForUpdates: Bool = false
#else
        let shouldCheckForUpdates: Bool = !SNUtilitiesKit.isRunningTests
#endif
        
        guard shouldCheckForUpdates else {
            var updatedJob: Job = job.with(
                failureCount: 0,
                nextRunTimestamp: (dependencies.dateNow.timeIntervalSince1970 + updateCheckFrequency)
            )
            dependencies[singleton: .storage].write { db in
                try updatedJob.upsert(db)
            }
            
            Log.info(.cat, "Deferred due to test/simulator build.")
            return deferred(updatedJob)
        }
        
        dependencies[singleton: .network]
            .checkClientVersion(ed25519SecretKey: dependencies[cache: .general].ed25519SecretKey)
            .subscribe(on: scheduler, using: dependencies)
            .receive(on: scheduler, using: dependencies)
            .sinkUntilComplete(
                receiveCompletion: { _ in
                    var updatedJob: Job = job.with(
                        failureCount: 0,
                        nextRunTimestamp: (dependencies.dateNow.timeIntervalSince1970 + updateCheckFrequency)
                    )
                    
                    dependencies[singleton: .storage].write { db in
                        try updatedJob.upsert(db)
                    }
                    
                    success(updatedJob, false)
                },
                receiveValue: { _, versionInfo in
                    switch versionInfo.prerelease {
                        case .none:
                            Log.info(.cat, "Latest version: \(versionInfo.version) (Current: \(dependencies[cache: .appVersion].versionInfo))")
                            
                        case .some(let prerelease):
                            Log.info(.cat, "Latest version: \(versionInfo.version), pre-release version: \(prerelease.version) (Current: \(dependencies[cache: .appVersion].versionInfo))")
                    }
                }
            )
    }
}
