// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUtilitiesKit
import SessionNetworkingKit

// MARK: - Log.Category

private extension Log.Category {
    static let cat: Log.Category = .create("ReuploadUserDisplayPictureJob", defaultLevel: .info)
}

// MARK: - ReuploadUserDisplayPictureJob

public enum ReuploadUserDisplayPictureJob: JobExecutor {
    public static let maxFailureCount: Int = -1
    public static let requiresThreadId: Bool = false
    public static let requiresInteractionId: Bool = false
    private static let maxExtendTTLFrequency: TimeInterval = (60 * 60 * 2)
    private static let maxDisplayPictureTTL: TimeInterval = (60 * 60 * 24 * 14)
    private static let maxReuploadFrequency: TimeInterval = (maxDisplayPictureTTL - (60 * 60 * 24 * 2))
    
    public static func run<S: Scheduler>(
        _ job: Job,
        scheduler: S,
        success: @escaping (Job, Bool) -> Void,
        failure: @escaping (Job, Error, Bool) -> Void,
        deferred: @escaping (Job) -> Void,
        using dependencies: Dependencies
    ) {
        /// Don't run when inactive or not in main app
        guard dependencies[defaults: .appGroup, key: .isMainAppActive] else {
            return deferred(job)
        }
        
        Task {
            // TODO: Wait until we've received a poll response before running the logic?
            // TODO: Check whether the image needs to be reprocessed
            // TODO: Try to extend the TTL
            
            let lastAttempt: Date = (
                dependencies[defaults: .standard, key: .lastUserDisplayPictureRefresh] ??
                Date.distantPast
            )
            
            /// Only try to extend the TTL of the users display pic if enough time has passed since the last attempt
            guard dependencies.dateNow.timeIntervalSince(lastAttempt) > maxExtendTTLFrequency else {
                /// Reset the `nextRunTimestamp` value just in case the last run failed so we don't get stuck in a loop endlessly
                /// deferring the job
                if let jobId: Int64 = job.id {
                    try await dependencies[singleton: .storage].writeAsync { db in
                        try Job
                            .filter(id: jobId)
                            .updateAll(db, Job.Columns.nextRunTimestamp.set(to: 0))
                    }
                
                }
                Log.info(.cat, "Deferred as not enough time has passed since the last update")
                return scheduler.schedule {
                    deferred(job)
                }
            }
            
            /// Retrieve the users profile data
            let profile: Profile = dependencies.mutate(cache: .libSession) { $0.profile }
            
            /// If we don't have a display pic then no need to do anything
            guard let displayPictureUrl: URL = profile.displayPictureUrl.map({ URL(string: $0) }) else {
                Log.info(.cat, "User has no display picture")
                return scheduler.schedule {
                    success(job, false)
                }
            }
            
            //        let displayPictureUpdate: DisplayPictureManager.Update = profile.displayPictureUrl
            //            .map { try? dependencies[singleton: .displayPictureManager].path(for: $0) }
            //            .map { dependencies[singleton: .fileManager].contents(atPath: $0) }
            //            .map { .currentUserUploadImageData($0) }
            //            .defaulting(to: .none)
            
            /// Try to extend the TTL of the existing profile pic first
            do {
                let preparedRequest: Network.PreparedRequest<FileUploadResponse> = try Network.FileServer.preparedExtend(
                    url: displayPictureUrl,
                    ttl: maxDisplayPictureTTL,
                    serverPubkey: Network.FileServer.fileServerPublicKey,
                    using: dependencies
                )
                var response: FileUploadResponse?
                var requestError: Error?
                let semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)
                
                preparedRequest
                    .send(using: dependencies)
                    .sinkUntilComplete(
                        receiveCompletion: { result in
                            switch result {
                                case .finished: break /// The `receiveValue` closure will handle
                                case .failure(let error):
                                    requestError = error
                                    semaphore.signal()
                            }
                        },
                        receiveValue: { _, fileUploadResponse in
                            response = fileUploadResponse
                            semaphore.signal()
                        }
                    )
                
                /// Wait for the request to complete
                semaphore.wait()
                
                // TODO: If it's a `NotFound` error then we should do the standard reupload logic
                
                /// If we get a `404` it means we couldn't extend the TTL of the file so need to re-upload
                switch (response, requestError) {
                    case (_, NetworkError.notFound): break
                    case (_, .some(let error)):
                        return scheduler.schedule {
                            failure(job, error, false)
                        }
                        
                    case (.none, .none): break
                        /// An unknown error occured (we got no response and no error - shouldn't be possible)
                        return scheduler.schedule {
                            failure(job, DisplayPictureError.uploadFailed, false)
                        }
                        
                    case (.some, .none):
                        Log.info(.cat, "Existing profile expiration extended")
                        
                        return scheduler.schedule {
                            success(job, false)
                        }
                }
                
                /// Determine whether we need to re-process the display picture before re-uploading it
                var needsReprocessing: Bool = ((profile.profileLastUpdated ?? 0) == 0)
                
                if !needsReprocessing {
                    try? dependencies[singleton: .displayPictureManager].path(for: $0)
                    displayPictureUrl
                }
                
                
                //profile.pro
                // TODO: If `shortenFileTTL` is set then reupload even if it's less than the 12 day timeout
                // TODO: Update the timestamp on successful extend
                //            dependencies[defaults: .standard, key: .lastUserDisplayPictureReupload] = dependencies.dateNow
            }
            catch {
                failure(job, error, false)
            }
            
            //        // Only re-upload the profile picture if enough time has passed since the last upload
            //        guard
            //            let lastAttempt: Date = dependencies[defaults: .standard, key: .lastProfilePictureReuploadAttempt],
            //            dependencies.dateNow.timeIntervalSince(lastProfilePictureUpload) > (14 * 24 * 60 * 60)
            //        else {
            //            // Reset the `nextRunTimestamp` value just in case the last run failed so we don't get stuck
            //            // in a loop endlessly deferring the job
            //            if let jobId: Int64 = job.id {
            //                dependencies[singleton: .storage].write { db in
            //                    try Job
            //                        .filter(id: jobId)
            //                        .updateAll(db, Job.Columns.nextRunTimestamp.set(to: 0))
            //                }
            //            }
            //
            //            Log.info(.cat, "Deferred as not enough time has passed since the last update")
            //            return deferred(job)
            //        }
            //
            //        /// **Note:** The `lastProfilePictureUpload` value is updated in `DisplayPictureManager`
            //        let profile: Profile = dependencies.mutate(cache: .libSession) { $0.profile }
            //        let displayPictureUpdate: DisplayPictureManager.Update = profile.displayPictureUrl
            //            .map { try? dependencies[singleton: .displayPictureManager].path(for: $0) }
            //            .map { dependencies[singleton: .fileManager].contents(atPath: $0) }
            //            .map { .currentUserUploadImageData($0) }
            //            .defaulting(to: .none)
            //
            //        Profile
            //            .updateLocal(
            //                displayPictureUpdate: displayPictureUpdate,
            //                using: dependencies
            //            )
            //            .subscribe(on: scheduler, using: dependencies)
            //            .receive(on: scheduler, using: dependencies)
            //            .sinkUntilComplete(
            //                receiveCompletion: { result in
            //                    switch result {
            //                        case .failure(let error): failure(job, error, false)
            //                        case .finished:
            //                            Log.info(.cat, "Profile successfully updated")
            //                            success(job, false)
            //                    }
            //                }
            //            )
        }
    }
}
