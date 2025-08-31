// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUtilitiesKit

// MARK: - Log.Category

private extension Log.Category {
    static let cat: Log.Category = .create("UpdateProfilePictureJob", defaultLevel: .info)
}

// MARK: - UpdateProfilePictureJob

public enum UpdateProfilePictureJob: JobExecutor {
    public static let maxFailureCount: Int = -1
    public static let requiresThreadId: Bool = false
    public static let requiresInteractionId: Bool = false
    
    public static func run(_ job: Job, using dependencies: Dependencies) async throws -> JobExecutionResult {
        /// Don't run when inactive or not in main app
        guard dependencies[defaults: .appGroup, key: .isMainAppActive] else {
            return .deferred(job) /// Don't need to do anything if it's not the main app
        }
        
        /// Only re-upload the profile picture if enough time has passed since the last upload
        guard
            let lastProfilePictureUpload: Date = dependencies[defaults: .standard, key: .lastProfilePictureUpload],
            dependencies.dateNow.timeIntervalSince(lastProfilePictureUpload) > (14 * 24 * 60 * 60)
        else {
            /// Reset the `nextRunTimestamp` value just in case the last run failed so we don't get stuck in a loop endlessly
            /// deferring the job
            Log.info(.cat, "Deferred as not enough time has passed since the last update")
            return .deferred(job.with(nextRunTimestamp: 0))
        }
        
        /// **Note:** The `lastProfilePictureUpload` value is updated in `DisplayPictureManager`
        let profile: Profile = dependencies.mutate(cache: .libSession) { $0.profile }
        let displayPictureUpdate: DisplayPictureManager.Update = profile.displayPictureUrl
            .map { try? dependencies[singleton: .displayPictureManager].path(for: $0) }
            .map { dependencies[singleton: .fileManager].contents(atPath: $0) }
            .map { .currentUserUploadImageData($0) }
            .defaulting(to: .none)
        
        // FIXME: Refactor this to use async/await
        let publisher = Profile.updateLocal(
            displayPictureUpdate: displayPictureUpdate,
            using: dependencies
        )
        
        _ = try await publisher.values.first(where: { _ in true })
        Log.info(.cat, "Profile successfully updated")
        return .success(job, stop: false)
    }
}
