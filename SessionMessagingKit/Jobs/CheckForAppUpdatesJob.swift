// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionNetworkingKit
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
    
    public static func run(_ job: Job, using dependencies: Dependencies) async throws -> JobExecutionResult {
        /// Just defer the update check when running tests or in the simulator
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
            try? await dependencies[singleton: .storage].writeAsync { db in
                try updatedJob.upsert(db)
            }
            
            Log.info(.cat, "Deferred due to test/simulator build.")
            return .deferred(updatedJob)
        }
        
        // FIXME: Refactor this to use async/await
        let publisher = dependencies[singleton: .network].checkClientVersion(
            ed25519SecretKey: dependencies[cache: .general].ed25519SecretKey
        )
        
        let versionInfo = try? await publisher.values.first(where: { _ in true })
        
        switch versionInfo?.1.prerelease {
            case .none:
                Log.info(.cat, "Latest version: \(versionInfo?.1.version ?? "Unknown (error)") (Current: \(dependencies[cache: .appVersion].versionInfo))")
                
            case .some(let prerelease):
                Log.info(.cat, "Latest version: \(versionInfo?.1.version ?? "Unknown (error)"), pre-release version: \(prerelease.version) (Current: \(dependencies[cache: .appVersion].versionInfo))")
        }
        
        let updatedJob: Job = job.with(
            failureCount: 0,
            nextRunTimestamp: (dependencies.dateNow.timeIntervalSince1970 + updateCheckFrequency)
        )
        return .success(updatedJob, stop: false)
    }
}
