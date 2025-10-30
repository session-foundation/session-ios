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
            guard
                await dependencies[singleton: .currentUserPoller].successfulPollCount
                    .first(where: { $0 > 0 }) != nil
            else {
                Log.info(.cat, "Deferred due to never receiving an initial poll response")
                return scheduler.schedule {
                    deferred(job)
                }
            }
            
            /// Retrieve the users profile data
            let profile: Profile = dependencies.mutate(cache: .libSession) { $0.profile }
            
            /// If we don't have a display pic then no need to do anything
            guard
                let displayPictureUrl: URL = profile.displayPictureUrl.map({ URL(string: $0) }),
                let displayPictureEncryptionKey: Data = profile.displayPictureEncryptionKey
            else {
                Log.info(.cat, "User has no display picture")
                return scheduler.schedule {
                    success(job, false)
                }
            }
            
            guard
                let filePath: String = try? dependencies[singleton: .displayPictureManager]
                    .path(for: displayPictureUrl.absoluteString),
                dependencies[singleton: .fileManager].fileExists(atPath: filePath)
            else {
                Log.warn(.cat, "User has display picture but file was not found")
                return scheduler.schedule {
                    success(job, false)
                }
            }
            
            /// Only try to extend the TTL of the users display pic if enough time has passed since it was last updated
            let lastUpdated: Date = Date(timeIntervalSince1970: profile.profileLastUpdated ?? 0)
            
            guard dependencies.dateNow.timeIntervalSince(lastUpdated) > maxExtendTTLFrequency || dependencies[feature: .shortenFileTTL] else {
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
            
            /// Try to extend the TTL of the existing profile pic first (default to providing no TTL which will extend to the server
            /// configuration)
            do {
                let targetTTL: TimeInterval? = (dependencies[feature: .shortenFileTTL] ? 60 : nil)
                let request: Network.PreparedRequest<Network.FileServer.ExtendExpirationResponse> = try Network.FileServer.preparedExtend(
                    url: displayPictureUrl,
                    customTtl: targetTTL,
                    using: dependencies
                )
                
                // FIXME: Make this async/await when the refactored networking is merged
                _ = try await request
                    .send(using: dependencies)
                    .values
                    .first(where: { _ in true })?.1 ?? { throw AttachmentError.uploadFailed }()
                
                /// Even though the data hasn't changed, we need to trigger `Profile.UpdateLocal` in order for the
                /// `profileLastUpdated` value to be updated correctly
                try await Profile.updateLocal(
                    displayPictureUpdate: .currentUserUpdateTo(
                        url: displayPictureUrl.absoluteString,
                        key: displayPictureEncryptionKey,
                        sessionProProof: dependencies.mutate(cache: .libSession) { $0.getProProof() },
                        isReupload: true
                    ),
                    using: dependencies
                )
                Log.info(.cat, "Existing profile expiration extended")
                
                return scheduler.schedule {
                    success(job, false)
                }
            } catch NetworkError.notFound {
                /// If we get a `404` it means we couldn't extend the TTL of the file so need to re-upload
            } catch {
                return scheduler.schedule {
                    failure(job, error, false)
                }
            }
            
            /// Since we made it here it means that refreshing the TTL failed so we may need to reupload the display picture
            do {
                let pendingDisplayPicture: PendingAttachment = PendingAttachment(
                    source: .media(.url(URL(fileURLWithPath: filePath))),
                    using: dependencies
                )
                
                guard
                    profile.profileLastUpdated == 0 ||
                    dependencies.dateNow.timeIntervalSince(lastUpdated) > maxReuploadFrequency ||
                    dependencies[feature: .shortenFileTTL] ||
                    dependencies[singleton: .displayPictureManager].reuploadNeedsPreparation(
                        attachment: pendingDisplayPicture
                    )
                else {
                    /// Reset the `nextRunTimestamp` value just in case the last run failed so we don't get stuck in a loop endlessly
                    /// deferring the job
                    if let jobId: Int64 = job.id {
                        dependencies[singleton: .storage].write { db in
                            try Job
                                .filter(id: jobId)
                                .updateAll(db, Job.Columns.nextRunTimestamp.set(to: 0))
                        }
                    }
        
                    return scheduler.schedule {
                        Log.info(.cat, "Deferred as not enough time has passed since the last update")
                        deferred(job)
                    }
                }
                
                /// Prepare and upload the display picture
                let preparedAttachment: PreparedAttachment = try await dependencies[singleton: .displayPictureManager]
                    .prepareDisplayPicture(attachment: pendingDisplayPicture)
                let result = try await dependencies[singleton: .displayPictureManager]
                    .uploadDisplayPicture(preparedAttachment: preparedAttachment)
                
                /// Update the local state now that the display picture has finished uploading
                try await Profile.updateLocal(
                    displayPictureUpdate: .currentUserUpdateTo(
                        url: result.downloadUrl,
                        key: result.encryptionKey,
                        sessionProProof: dependencies.mutate(cache: .libSession) { $0.getProProof() },
                        isReupload: true
                    ),
                    using: dependencies
                )
                
                return scheduler.schedule {
                    Log.info(.cat, "Profile successfully updated")
                    success(job, false)
                }
            }
            catch {
                return scheduler.schedule {
                    failure(job, error, false)
                }
            }
        }
    }
}
