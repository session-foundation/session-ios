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
    
    public static func run<S: Scheduler>(
        _ job: Job,
        scheduler: S,
        success: @escaping (Job, Bool) -> Void,
        failure: @escaping (Job, Error, Bool) -> Void,
        deferred: @escaping (Job) -> Void,
        using dependencies: Dependencies
    ) {
        // Don't run when inactive or not in main app or if the user doesn't exist yet
        guard dependencies[defaults: .appGroup, key: .isMainAppActive] else {
            return deferred(job) // Don't need to do anything if it's not the main app
        }
        guard dependencies[singleton: .onboarding].syncState.state == .completed else {
            Log.info(.syncPushTokensJob, "Deferred due to incomplete registration")
            return deferred(job)
        }
        
        /// Since this job can be dependant on network conditions it's possible for multiple jobs to run at the same time, while this shouldn't cause issues
        /// it can result in multiple API calls getting made concurrently so to avoid this we defer the job as if the previous one was successful then the
        ///  `lastDeviceTokenUpload` value will prevent the subsequent call being made
        guard
            dependencies[singleton: .jobRunner]
                .jobInfoFor(state: .running, variant: .syncPushTokens)
                .filter({ key, info in key != job.id })     // Exclude this job
                .isEmpty
        else {
            // Defer the job to run 'maxRunFrequency' from when this one ran (if we don't it'll try start
            // it again immediately which is pointless)
            let updatedJob: Job? = dependencies[singleton: .storage].write { db in
                try job
                    .with(nextRunTimestamp: dependencies.dateNow.timeIntervalSince1970 + maxRunFrequency)
                    .upserted(db)
            }
            
            Log.info(.syncPushTokensJob, "Deferred due to in progress job")
            return deferred(updatedJob ?? job)
        }
        
        // Determine if the device has 'Fast Mode' (APNS) enabled
        let isUsingFullAPNs: Bool = dependencies[defaults: .standard, key: .isUsingFullAPNs]
        
        // If the job is running and 'Fast Mode' is disabled then we should try to unregister the existing
        // token
        guard isUsingFullAPNs else {
            Task {
                // Get the last token we subscribed with
                let lastRecordedPushToken: String? = try? await dependencies[singleton: .storage].readAsync { db in
                    db[.lastRecordedPushToken]
                }
                
                // Tell the device to unregister for remote notifications (essentially try to invalidate
                // the token if needed - we do this first to avoid wrid race conditions which could be
                // triggered by the user immediately re-registering)
                await UIApplication.shared.unregisterForRemoteNotifications()
                
                // Clear the old token
                try? await dependencies[singleton: .storage].writeAsync { db in
                    db[.lastRecordedPushToken] = nil
                }
                
                // Unregister from our server
                if let existingToken: String = lastRecordedPushToken {
                    Log.info(.syncPushTokensJob, "Unregister using last recorded push token: \(redact(existingToken))")
                    do {
                        try await PushNotificationAPI.unsubscribeAll(
                            token: Data(hex: existingToken),
                            using: dependencies
                        )
                        Log.info(.syncPushTokensJob, "Unregister Completed")
                    }
                    catch {
                        Log.error(.syncPushTokensJob, "Unregister Failed with error: \(error)")
                    }
                    return
                }
                else {
                    Log.info(.syncPushTokensJob, "No previous token stored just triggering device unregister")
                }
                
                // We want to complete this job regardless of success or failure
                success(job, false)
            }
            return
        }
        
        /// Perform device registration
        ///
        /// **Note:** Apple's documentation states that we should re-register for notifications on every launch:
        /// https://developer.apple.com/library/archive/documentation/NetworkingInternet/Conceptual/RemoteNotificationsPG/HandlingRemoteNotifications.html#//apple_ref/doc/uid/TP40008194-CH6-SW1
        Log.info(.syncPushTokensJob, "Re-registering for remote notifications")
        
        // FIXME: We should refactor this entire process to be async/await
        dependencies[singleton: .pushRegistrationManager].requestPushTokens()
            .sinkUntilComplete(
                receiveCompletion: { result in
                    /// Just succeed on failure
                    switch result {
                        case .finished: break
                        case .failure: success(job, false)
                    }
                },
                receiveValue: { (pushToken: String, voipToken: String) in
                    Task {
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
                            return success(job, false)
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
                            return success(job, false)
                        }
                        
                        Log.info(.syncPushTokensJob, "Sending push token to PN server")
                        
                        /// Retry up to 3 times
                        for _ in 0..<3 {
                            do {
                                try await PushNotificationAPI.subscribeAll(
                                    token: Data(hex: pushToken),
                                    isForcedUpdate: true,
                                    using: dependencies
                                )
                                Log.debug(.syncPushTokensJob, "Recording push tokens locally. pushToken: \(redact(pushToken)), voipToken: \(redact(voipToken))")
                                Log.info(.syncPushTokensJob, "Completed")
                                
                                dependencies[singleton: .storage].write { db in
                                    db[.lastRecordedPushToken] = pushToken
                                    db[.lastRecordedVoipToken] = voipToken
                                }
                                break
                            }
                            catch { Log.error(.syncPushTokensJob, "Failed to register due to error: \(error)") }
                        }
                        
                        /// We want to complete this job regardless of success or failure
                        return success(job, false)
                    }
                }
            )
    }
    
    public static func run(uploadOnlyIfStale: Bool, using dependencies: Dependencies) -> AnyPublisher<Void, Error> {
        return Deferred {
            Future<Void, Error> { resolver in
                guard let job: Job = Job(
                    variant: .syncPushTokens,
                    behaviour: .runOnce,
                    details: SyncPushTokensJob.Details(
                        uploadOnlyIfStale: uploadOnlyIfStale
                    )
                )
                else { return resolver(Result.failure(NetworkError.parsingFailed)) }
                
                SyncPushTokensJob.run(
                    job,
                    scheduler: DispatchQueue.global(qos: .userInitiated),
                    success: { _, _ in resolver(Result.success(())) },
                    failure: { _, error, _ in resolver(Result.failure(error)) },
                    deferred: { job in
                        dependencies[singleton: .jobRunner]
                            .afterJob(job)
                            .first()
                            .sinkUntilComplete(
                                receiveValue: { result in
                                    switch result {
                                        /// If it gets deferred a second time then we should probably just fail - no use waiting on something
                                        /// that may never run (also means we can avoid another potential defer loop)
                                        case .notFound, .deferred: resolver(Result.failure(NetworkError.unknown))
                                        case .failed(let error, _): resolver(Result.failure(error))
                                        case .succeeded: resolver(Result.success(()))
                                    }
                                }
                            )
                    },
                    using: dependencies
                )
            }
        }
        .eraseToAnyPublisher()
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
