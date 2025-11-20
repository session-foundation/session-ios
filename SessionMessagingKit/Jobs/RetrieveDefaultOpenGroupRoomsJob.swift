// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionNetworkingKit
import SessionUtilitiesKit

// MARK: - Log.Category

private extension Log.Category {
    static let cat: Log.Category = .create("RetrieveDefaultOpenGroupRoomsJob", defaultLevel: .info)
}

// MARK: - RetrieveDefaultOpenGroupRoomsJob

public enum RetrieveDefaultOpenGroupRoomsJob: JobExecutor {
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
        /// Don't run when inactive or not in main app
        ///
        /// Additionally, since this job can be triggered by the user viewing the "Join Community" screen it's possible for multiple jobs to run at
        /// the same time, we don't want to waste bandwidth by making redundant calls to fetch the default rooms so don't do anything if there
        /// is already a job running
        guard
            dependencies[defaults: .appGroup, key: .isMainAppActive],
            dependencies[singleton: .jobRunner]
                .jobInfoFor(state: .running, variant: .retrieveDefaultOpenGroupRooms)
                .filter({ key, info in key != job.id })     // Exclude this job
                .isEmpty
        else { return deferred(job) }
        
        Task {
            do {
                let request = try Network.SOGS.preparedCapabilitiesAndRooms(
                    authMethod: Network.SOGS.defaultAuthMethod,
                    skipAuthentication: true,
                    using: dependencies
                )
                // FIXME: Make this async/await when the refactored networking is merged
                let response: Network.SOGS.CapabilitiesAndRoomsResponse = try await request
                    .send(using: dependencies)
                    .values
                    .first(where: { _ in true })?.1 ?? { throw NetworkError.invalidResponse }()
                guard !Task.isCancelled else { return }
                
                /// Store the updated capabilities and schedule downloads for the room images (if they
                /// are already downloaded then the job will just complete)
                try await dependencies[singleton: .storage].writeAsync { db in
                    dependencies[singleton: .communityManager].handleCapabilities(
                        db,
                        capabilities: response.capabilities.data,
                        server: Network.SOGS.defaultServer,
                        publicKey: Network.SOGS.defaultServerPublicKey
                    )
                    
                    response.rooms.data.forEach { info in
                        guard let imageId: String = info.imageId else { return }
                        
                        dependencies[singleton: .jobRunner].add(
                            db,
                            job: Job(
                                variant: .displayPictureDownload,
                                shouldBeUnique: true,
                                details: DisplayPictureDownloadJob.Details(
                                    target: .community(
                                        imageId: imageId,
                                        roomToken: info.token,
                                        server: Network.SOGS.defaultServer
                                    ),
                                    timestamp: (dependencies[cache: .snodeAPI].currentOffsetTimestampMs() / 1000)
                                )
                            ),
                            canStartJob: true
                        )
                    }
                }
                
                /// Update the `CommunityManager` cache of room and capability data
                await dependencies[singleton: .communityManager].updateRooms(
                    rooms: response.rooms.data,
                    server: Network.SOGS.defaultServer,
                    publicKey: Network.SOGS.defaultServerPublicKey,
                    areDefaultRooms: true
                )
                Log.info(.cat, "Successfully retrieved default Community rooms")
                
                scheduler.schedule {
                    success(job, false)
                }
            }
            catch {
                /// We want to fail permanently here, otherwise we would just indefinitely retry (if the user opens the
                /// "Join Community" screen that will kick off another job, otherwise this will automatically be rescheduled
                /// on launch)
                Log.error(.cat, "Failed to get default Community rooms due to error: \(error)")
                scheduler.schedule {
                    failure(job, error, true)
                }
            }
        }
    }
    
    public static func run(using dependencies: Dependencies) {
        RetrieveDefaultOpenGroupRoomsJob.run(
            Job(variant: .retrieveDefaultOpenGroupRooms, behaviour: .runOnce),
            scheduler: DispatchQueue.global(qos: .default),
            success: { _, _ in },
            failure: { _, _, _ in },
            deferred: { _ in },
            using: dependencies
        )
    }
}
