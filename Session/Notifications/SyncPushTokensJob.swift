// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SignalCoreKit
import SessionMessagingKit
import SessionUtilitiesKit
import SignalCoreKit

public enum SyncPushTokensJob: JobExecutor {
    public static let maxFailureCount: Int = -1
    public static let requiresThreadId: Bool = false
    public static let requiresInteractionId: Bool = false
    
    public static func run(
        _ job: Job,
        queue: DispatchQueue,
        success: @escaping (Job, Bool) -> (),
        failure: @escaping (Job, Error?, Bool) -> (),
        deferred: @escaping (Job) -> ()
    ) {
        // Don't run when inactive or not in main app
        guard (UserDefaults.sharedLokiProject?[.isMainAppActive]).defaulting(to: false) else {
            deferred(job) // Don't need to do anything if it's not the main app
            return
        }
        
        // We need to check a UIApplication setting which needs to run on the main thread so if we aren't on
        // the main thread then swap to it
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                run(job, queue: queue, success: success, failure: failure, deferred: deferred)
            }
            return
        }
        
        // Push tokens don't normally change while the app is launched, so checking once during launch is
        // usually sufficient, but e.g. on iOS11, users who have disabled "Allow Notifications" and disabled
        // "Background App Refresh" will not be able to obtain an APN token. Enabling those settings does not
        // restart the app, so we check every activation for users who haven't yet registered.
        guard job.behaviour != .recurringOnActive || !UIApplication.shared.isRegisteredForRemoteNotifications else {
            deferred(job) // Don't need to do anything if push notifications are already registered
            return
        }
        
        Logger.info("Retrying remote notification registration since user hasn't registered yet.")
        
        // Determine if we want to upload only if stale (Note: This should default to true, and be true if
        // 'details' isn't provided)
        let uploadOnlyIfStale: Bool = ((try? JSONDecoder().decode(Details.self, from: job.details ?? Data()))?.uploadOnlyIfStale ?? true)
        
        // Get the app version info (used to determine if we want to update the push tokens)
        let lastAppVersion: String? = AppVersion.sharedInstance().lastAppVersion
        let currentAppVersion: String? = AppVersion.sharedInstance().currentAppVersion
        
        PushRegistrationManager.shared.requestPushTokens()
            .subscribe(on: queue)
            .flatMap { (pushToken: String, voipToken: String) -> AnyPublisher<Void, Error> in
                let lastPushToken: String? = Storage.shared[.lastRecordedPushToken]
                let lastVoipToken: String? = Storage.shared[.lastRecordedVoipToken]
                let shouldUploadTokens: Bool = (
                    !uploadOnlyIfStale || (
                        lastPushToken != pushToken ||
                        lastVoipToken != voipToken
                    ) ||
                    lastAppVersion != currentAppVersion
                )

                guard shouldUploadTokens else {
                    return Just(())
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
                }
                
                return Deferred {
                    Future<Void, Error> { resolver in
                        SyncPushTokensJob.registerForPushNotifications(
                            pushToken: pushToken,
                            voipToken: voipToken,
                            isForcedUpdate: shouldUploadTokens,
                            success: { resolver(Result.success(())) },
                            failure: { resolver(Result.failure($0)) }
                        )
                    }
                }
                .handleEvents(
                    receiveCompletion: { result in
                        switch result {
                            case .failure: break
                            case .finished:
                                Logger.warn("Recording push tokens locally. pushToken: \(redact(pushToken)), voipToken: \(redact(voipToken))")

                                Storage.shared.write { db in
                                    db[.lastRecordedPushToken] = pushToken
                                    db[.lastRecordedVoipToken] = voipToken
                                }
                        }
                    }
                )
                .eraseToAnyPublisher()
            }
            .sinkUntilComplete(
                // We want to complete this job regardless of success or failure
                receiveCompletion: { _ in success(job, false) },
                receiveValue: { _ in }
            )
    }
    
    public static func run(uploadOnlyIfStale: Bool) {
        guard let job: Job = Job(
            variant: .syncPushTokens,
            details: SyncPushTokensJob.Details(
                uploadOnlyIfStale: uploadOnlyIfStale
            )
        )
        else { return }
                                 
        SyncPushTokensJob.run(
            job,
            queue: DispatchQueue.global(qos: .default),
            success: { _, _ in },
            failure: { _, _, _ in },
            deferred: { _ in }
        )
    }
}

// MARK: - SyncPushTokensJob.Details

extension SyncPushTokensJob {
    public struct Details: Codable {
        public let uploadOnlyIfStale: Bool
    }
}

// MARK: - Convenience

private func redact(_ string: String) -> String {
    return OWSIsDebugBuild() ? string : "[ READACTED \(string.prefix(2))...\(string.suffix(2)) ]"
}

extension SyncPushTokensJob {
    fileprivate static func registerForPushNotifications(
        pushToken: String,
        voipToken: String,
        isForcedUpdate: Bool,
        success: @escaping () -> (),
        failure: @escaping (Error) -> (),
        remainingRetries: Int = 3
    ) {
        let isUsingFullAPNs: Bool = UserDefaults.standard[.isUsingFullAPNs]
        
        Just(Data(hex: pushToken))
            .setFailureType(to: Error.self)
            .flatMap { pushTokenAsData -> AnyPublisher<Bool, Error> in
                guard isUsingFullAPNs else {
                    return PushNotificationAPI.unregister(pushTokenAsData)
                        .map { _ in true }
                        .eraseToAnyPublisher()
                }
                
                return PushNotificationAPI
                    .register(
                        with: pushTokenAsData,
                        publicKey: getUserHexEncodedPublicKey(),
                        isForcedUpdate: isForcedUpdate
                    )
                    .map { _ in true }
                    .eraseToAnyPublisher()
            }
            .catch { error -> AnyPublisher<Bool, Error> in
                guard remainingRetries == 0 else {
                    SyncPushTokensJob.registerForPushNotifications(
                        pushToken: pushToken,
                        voipToken: voipToken,
                        isForcedUpdate: isForcedUpdate,
                        success: success,
                        failure: failure,
                        remainingRetries: (remainingRetries - 1)
                    )
                    
                    return Just(false)
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
                }
                
                return Fail(error: error)
                    .eraseToAnyPublisher()
            }
            .sinkUntilComplete(
                receiveCompletion: { result in
                    switch result {
                        case .finished: break
                        case .failure(let error): failure(error)
                    }
                },
                receiveValue: { didComplete in
                    guard didComplete else { return }
                    
                    success()
                }
            )
    }
}
