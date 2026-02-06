// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionNetworkingKit
import SessionMessagingKit
import SessionUtilitiesKit

// MARK: - Log.Category

public extension Log.Category {
    static let syncPushTokensJob: Log.Category = .create("SyncPushTokensJob", defaultLevel: .info)
}

// MARK: - SyncPushTokensJob

public enum SyncPushTokensJob: JobExecutor {
    public static let maxFailureCount: Int = -1
    public static let requiresThreadId: Bool = false
    public static let requiresInteractionId: Bool = false
    private static let maxFrequency: TimeInterval = (12 * 60 * 60)
    private static let maxRunFrequency: TimeInterval = 1
    
    public static func canRunConcurrentlyWith(
        runningJobs: [JobState],
        jobState: JobState,
        using dependencies: Dependencies
    ) -> Bool {
        /// Since this job can be dependant on network conditions it's possible for multiple jobs to run at the same time, while this
        /// shouldn't cause issues it can result in multiple API calls getting made concurrently so to avoid this we wait for the previous
        /// to finish and then rely on the `lastDeviceTokenUpload` value to prevent the subsequent API call being made
        return false
    }
    
    public static func run(_ job: Job, using dependencies: Dependencies) async throws -> JobExecutionResult {
        /// Don't run when inactive or not in main app or if the user doesn't exist yet
        guard dependencies[defaults: .appGroup, key: .isMainAppActive] else {
            return .success /// Don't need to do anything if it's not the main app
        }
        
        /// Wait for `libSession` and `onboarding` to be loaded so we have the users proper state
        await dependencies.hasBeenInitialised(cache: .libSession)
        await dependencies.hasBeenInitialised(singleton: .onboarding)
        
        guard
            !dependencies[cache: .libSession].isEmpty,
            await dependencies[singleton: .onboarding].state.first() == .completed
        else {
            Log.info(.syncPushTokensJob, "Ignored due to incomplete registration")
            return .success
        }
        
        /// Determine if the device has 'Fast Mode' (APNS) enabled
        let isUsingFullAPNs: Bool = dependencies[defaults: .standard, key: .isUsingFullAPNs]
        
        /// If the job is running and 'Fast Mode' is disabled then we should try to unregister the existing token
        guard isUsingFullAPNs else {
            do {
                let lastRecordedPushToken: String? = try await dependencies[singleton: .storage].readAsync { db in
                    db[.lastRecordedPushToken]
                }
                
                /// Tell the device to unregister for remote notifications (essentially try to invalidate the token if needed - we do this
                /// first to avoid wrid race conditions which could be triggered by the user immediately re-registering)
                await UIApplication.shared.unregisterForRemoteNotifications()
                
                if let existingToken: String = lastRecordedPushToken {
                    /// Clear the old token
                    try await dependencies[singleton: .storage].writeAsync { db in
                        db[.lastRecordedPushToken] = nil
                    }
                    
                    /// Unregister from our server
                    Log.info(.syncPushTokensJob, "Unregister using last recorded push token: \(redact(existingToken))")
                    try await Network.PushNotification
                        .unsubscribeAll(token: Data(hex: existingToken), using: dependencies)
                        .values
                        .first(where: { _ in true }) ?? { throw NetworkError.invalidResponse }()
                }
                else {
                    Log.info(.syncPushTokensJob, "No previous token stored just triggering device unregister")
                }
                
                Log.info(.syncPushTokensJob, "Unregister Completed")
                return .success
            }
            catch {
                /// We want to complete this job regardless of success or failure
                Log.error(.syncPushTokensJob, "Unregister Failed with error: \(error)")
                return .success
            }
        }
        
        /// Perform device registration
        ///
        /// **Note:** Apple's documentation states that we should re-register for notifications on every launch:
        /// https://developer.apple.com/library/archive/documentation/NetworkingInternet/Conceptual/RemoteNotificationsPG/HandlingRemoteNotifications.html#//apple_ref/doc/uid/TP40008194-CH6-SW1
        Log.info(.syncPushTokensJob, "Re-registering for remote notifications")
        
        // FIXME: Refactor this to use async/await
        let (pushToken, voipToken): (String, String) = dependencies[singleton: .pushRegistrationManager]
            .requestPushTokens()
            .values
            .first(where: { _ in true }) ?? { throw NetworkError.explicit("Unable to retrieve tokens from device") }())
            
        Log.info(.syncPushTokensJob, "Received push and voip tokens, waiting for paths to build")
        let hasConnection: Bool = await withThrowingTaskGroup { group in
            group.addTask {
                try await dependencies.waitUntilConnected(onWillStartWaiting: {
                    Log.info(.syncPushTokensJob, "Waiting for network to connect.")
                })
            }
            group.addTask {
                /// Give the paths a chance to build on launch/
                try await Task.sleep(for: .seconds(5))
                throw NetworkError.timeout(error: "", rawData: nil)
            }
            
            let output: Result<Void, Error>? = await group.nextResult()
            group.cancelAll()
            
            switch output {
                case .failure, .none: return false
                case .success: return true
            }
        }
        
        /// Just log and succeed on failure
        guard hasConnection else {
            Log.info(.syncPushTokensJob, "OS subscription completed, skipping server subscription due to path build timeout")
            return .success
        }
        
        /// Get the last token we subscribed with
        let lastRecordedPushToken: String? = try? await dependencies[singleton: .storage].readAsync { db in
            db[.lastRecordedPushToken]
        }
                        
        /// For our `subscribe` endpoint we only want to call it if:
        /// • It's been longer than `SyncPushTokensJob.maxFrequency` since the last successful subscription;
        /// • The token has changed; or
        /// • We want to force an update
        let timeSinceLastSuccessfulUpload: TimeInterval = dependencies.dateNow
            .timeIntervalSince(
                Date(timeIntervalSince1970: dependencies[defaults: .standard, key: .lastDeviceTokenUpload])
            )
        let uploadOnlyIfStale: Bool? = {
            guard
                let detailsData: Data = job.details,
                let details: Details = try? JSONDecoder().decode(Details.self, from: detailsData)
            else { return nil }
            
            return details.uploadOnlyIfStale
        }()
                        
        /// No need to re-subscribe on the push server
        guard
            timeSinceLastSuccessfulUpload >= SyncPushTokensJob.maxFrequency ||
            lastRecordedPushToken != pushToken ||
            uploadOnlyIfStale == false
        else {
            Log.info(.syncPushTokensJob, "OS subscription completed, skipping server subscription due to frequency")
            return .success
        }
        
        Log.info(.syncPushTokensJob, "Sending push token to PN server")
        
        /// Retry up to 3 times
        for _ in 0..<3 {
            do {
                try await Network.PushNotification.subscribeAll(
                    token: Data(hex: pushToken),
                    isForcedUpdate: true,
                    using: dependencies
                )
                Log.debug(.syncPushTokensJob, "Recording push tokens locally. pushToken: \(redact(pushToken)), voipToken: \(redact(voipToken))")
                Log.info(.syncPushTokensJob, "Completed")
                
                try await dependencies[singleton: .storage].writeAsync { db in
                    db[.lastRecordedPushToken] = pushToken
                    db[.lastRecordedVoipToken] = voipToken
                }
                break
            }
            catch { Log.error(.syncPushTokensJob, "Failed to register due to error: \(error)") }
        }
        
        /// We want to complete this job regardless of success or failure
        return .success
    }
    
    public static func run(uploadOnlyIfStale: Bool, using dependencies: Dependencies) async throws {
        let job: Job = try await dependencies[singleton: .storage].writeAsync { db in
            dependencies[singleton: .jobRunner].add(
                db,
                job: Job(
                    variant: .syncPushTokens,
                    details: SyncPushTokensJob.Details(
                        uploadOnlyIfStale: uploadOnlyIfStale
                    )
                )
            )
        } ?? { throw JobRunnerError.missingRequiredDetails }()
        
        /// Await the result of the job
        ///
        /// **Note:** We want to wait for the result of this specific job even though there may be another in progress because it's
        /// possible that this job has a different configuration to the other job
        let result: JobRunner.JobResult = try await dependencies[singleton: .jobRunner]
            .finalResult(for: job)
        
        /// Fail if we didn't get a successful result - no use waiting on something that may never run (also means we can avoid another
        /// potential defer loop)
        switch result {
            case .deferred: throw JobRunnerError.missingRequiredDetails
            case .failed(let error, _): throw error
            case .succeeded: break
        }
    }
}

// MARK: - SyncPushTokensJob.Details

extension SyncPushTokensJob {
    public struct Details: Codable {
        public let uploadOnlyIfStale: Bool
    }
}

// MARK: - Convenience

// stringlint:ignore_contents
private func redact(_ string: String) -> String {
#if DEBUG
    return "[ DEBUG_NOT_REDACTED \(string) ]"
#else
    return "[ READACTED \(string.prefix(2))...\(string.suffix(2)) ]"
#endif
}
