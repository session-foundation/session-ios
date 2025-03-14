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
    
    public static func run<S: Scheduler>(
        _ job: Job,
        scheduler: S,
        success: @escaping (Job, Bool) -> Void,
        failure: @escaping (Job, Error, Bool) -> Void,
        deferred: @escaping (Job) -> Void,
        using dependencies: Dependencies
    ) {
        // Don't run when inactive or not in main app
        guard dependencies[defaults: .appGroup, key: .isMainAppActive] else {
            return deferred(job) // Don't need to do anything if it's not the main app
        }
        
        // Only re-upload the profile picture if enough time has passed since the last upload
        guard
            let lastProfilePictureUpload: Date = dependencies[defaults: .standard, key: .lastProfilePictureUpload],
            dependencies.dateNow.timeIntervalSince(lastProfilePictureUpload) > (14 * 24 * 60 * 60)
        else {
            // Reset the `nextRunTimestamp` value just in case the last run failed so we don't get stuck
            // in a loop endlessly deferring the job
            if let jobId: Int64 = job.id {
                dependencies[singleton: .storage].write { db in
                    try Job
                        .filter(id: jobId)
                        .updateAll(db, Job.Columns.nextRunTimestamp.set(to: 0))
                }
            }

            Log.info(.cat, "Deferred as not enough time has passed since the last update")
            return deferred(job)
        }
        
        // Note: The user defaults flag is updated in DisplayPictureManager
        let profile: Profile = Profile.fetchOrCreateCurrentUser(using: dependencies)
        let displayPictureUpdate: DisplayPictureManager.Update = profile.profilePictureFileName
            .map { dependencies[singleton: .displayPictureManager].loadDisplayPictureFromDisk(for: $0) }
            .map { .currentUserUploadImageData($0) }
            .defaulting(to: .none)
        
        Profile
            .updateLocal(
                displayPictureUpdate: displayPictureUpdate,
                using: dependencies
            )
            .subscribe(on: scheduler, using: dependencies)
            .receive(on: scheduler, using: dependencies)
            .sinkUntilComplete(
                receiveCompletion: { result in
                    switch result {
                        case .failure(let error): failure(job, error, false)
                        case .finished:
                            Log.info(.cat, "Profile successfully updated")
                            success(job, false)
                    }
                }
            )
    }
}
