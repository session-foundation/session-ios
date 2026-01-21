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
    
    public static func run(_ job: Job, using dependencies: Dependencies) async throws -> JobExecutionResult {
        /// Don't run when inactive or not in main app
        guard dependencies[defaults: .appGroup, key: .isMainAppActive] else {
            return .success
        }
        
        /// Since this job can be triggered by the user viewing the "Join Community" screen it's possible for multiple jobs to run at the
        /// same time, we don't want to waste bandwidth by making redundant calls to fetch the default rooms so don't do anything if there
        /// is already a job running
        let maybeExistingJobState: JobState? = await dependencies[singleton: .jobRunner].firstJobMatching(
            filters: JobRunner.Filters(
                include: [
                    .variant(.retrieveDefaultOpenGroupRooms),
                    .status(.running)
                ],
                exclude: [
                    job.id.map { .jobId($0) }          /// Exclude this job
                ].compactMap { $0 }
            )
        )
        try Task.checkCancellation()
        
        if maybeExistingJobState != nil {
            return .success
        }
        
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
            try Task.checkCancellation()
            
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
                            details: DisplayPictureDownloadJob.Details(
                                target: .community(
                                    imageId: imageId,
                                    roomToken: info.token,
                                    server: Network.SOGS.defaultServer,
                                    skipAuthentication: true
                                ),
                                timestamp: (dependencies[cache: .snodeAPI].currentOffsetTimestampMs() / 1000)
                            )
                        )
                    )
                }
            }
            try Task.checkCancellation()
            
            /// Update the `CommunityManager` cache of room and capability data
            await dependencies[singleton: .communityManager].updateRooms(
                rooms: response.rooms.data,
                server: Network.SOGS.defaultServer,
                publicKey: Network.SOGS.defaultServerPublicKey,
                areDefaultRooms: true
            )
            try Task.checkCancellation()
            Log.info(.cat, "Successfully retrieved default Community rooms")
            
            return .success
        }
        catch {
            /// We want to fail permanently here, otherwise we would just indefinitely retry (if the user opens the
            /// "Join Community" screen that will kick off another job, otherwise this will automatically be rescheduled
            /// on launch)
            Log.error(.cat, "Failed to get default Community rooms due to error: \(error)")
            throw error
        }
    }
    
    public static func run(using dependencies: Dependencies) async throws {
        let job: Job = try await dependencies[singleton: .storage].writeAsync { db in
            dependencies[singleton: .jobRunner].add(
                db,
                job: Job(
                    variant: .retrieveDefaultOpenGroupRooms
                )
            )
        } ?? { throw JobRunnerError.missingRequiredDetails }()
        
        /// Await the result of the job
        ///
        /// **Note:** We want to wait for the result of this specific job even though there may be another in progress because it's
        /// possible that this job was triggered after a config change and a currently running job was started before the change (if on is
        /// running then this job will wait for it to complete and complete instantly if there and no pending changes to be pushed)
        let result: JobRunner.JobResult = await dependencies[singleton: .jobRunner].result(for: job)
        
        /// Fail if we didn't get a successful result - no use waiting on something that may never run (also means we can avoid another
        /// potential defer loop)
        switch result {
            case .notFound, .deferred: throw JobRunnerError.missingRequiredDetails
            case .failed(let error, _): throw error
            case .succeeded: break
        }
    }
}
