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
    private static let maxFrequency: TimeInterval = (12 * 60 * 60)
    
    public static func run(
        _ job: Job,
        queue: DispatchQueue,
        success: @escaping (Job, Bool, Dependencies) -> (),
        failure: @escaping (Job, Error?, Bool, Dependencies) -> (),
        deferred: @escaping (Job, Dependencies) -> (),
        using dependencies: Dependencies = Dependencies()
    ) {
        // Don't run when inactive or not in main app or if the user doesn't exist yet
        guard (UserDefaults.sharedLokiProject?[.isMainAppActive]).defaulting(to: false) else {
            return deferred(job, dependencies) // Don't need to do anything if it's not the main app
        }
        guard Identity.userCompletedRequiredOnboarding() else {
            SNLog("[SyncPushTokensJob] Deferred due to incomplete registration")
            return deferred(job, dependencies)
        }
        
        // We need to check a UIApplication setting which needs to run on the main thread so synchronously
        // retrieve the value so we can continue
        let isRegisteredForRemoteNotifications: Bool = {
            guard !Thread.isMainThread else {
                return UIApplication.shared.isRegisteredForRemoteNotifications
            }
            
            return DispatchQueue.main.sync {
                return UIApplication.shared.isRegisteredForRemoteNotifications
            }
        }()
        
        // Apple's documentation states that we should re-register for notifications on every launch:
        // https://developer.apple.com/library/archive/documentation/NetworkingInternet/Conceptual/RemoteNotificationsPG/HandlingRemoteNotifications.html#//apple_ref/doc/uid/TP40008194-CH6-SW1
        guard job.behaviour == .runOnce || !isRegisteredForRemoteNotifications else {
            SNLog("[SyncPushTokensJob] Deferred due to Fast Mode disabled")
            deferred(job, dependencies) // Don't need to do anything if push notifications are already registered
            return
        }
        
        // Determine if the device has 'Fast Mode' (APNS) enabled
        let isUsingFullAPNs: Bool = UserDefaults.standard[.isUsingFullAPNs]
        
        // If the job is running and 'Fast Mode' is disabled then we should try to unregister the existing
        // token
        guard isUsingFullAPNs else {
            Just(Storage.shared[.lastRecordedPushToken])
                .setFailureType(to: Error.self)
                .flatMap { lastRecordedPushToken in
                    if let existingToken: String = lastRecordedPushToken {
                        SNLog("[SyncPushTokensJob] Unregister using last recorded push token: \(redact(existingToken))")
                        return Just(existingToken)
                            .setFailureType(to: Error.self)
                            .eraseToAnyPublisher()
                    }
                    
                    SNLog("[SyncPushTokensJob] Unregister using live token provided from device")
                    return PushRegistrationManager.shared.requestPushTokens()
                        .map { token, _ in token }
                        .eraseToAnyPublisher()
                }
                .flatMap { pushToken in PushNotificationAPI.unregister(Data(hex: pushToken)) }
                .map {
                    // Tell the device to unregister for remote notifications (essentially try to invalidate
                    // the token if needed
                    DispatchQueue.main.sync { UIApplication.shared.unregisterForRemoteNotifications() }
                    
                    Storage.shared.write { db in
                        db[.lastRecordedPushToken] = nil
                    }
                    return ()
                }
                .subscribe(on: queue)
                .sinkUntilComplete(
                    receiveCompletion: { result in
                        switch result {
                            case .finished: SNLog("[SyncPushTokensJob] Unregister Completed")
                            case .failure: SNLog("[SyncPushTokensJob] Unregister Failed")
                        }
                        
                        // We want to complete this job regardless of success or failure
                        success(job, false, dependencies)
                    }
                )
            return
        }
        
        // Perform device registration
        Logger.info("Re-registering for remote notifications.")
        PushRegistrationManager.shared.requestPushTokens()
            .flatMap { (pushToken: String, voipToken: String) -> AnyPublisher<Void, Error> in
                PushNotificationAPI
                    .register(
                        with: Data(hex: pushToken),
                        publicKey: getUserHexEncodedPublicKey(),
                        isForcedUpdate: true
                    )
                    .retry(3)
                    .handleEvents(
                        receiveCompletion: { result in
                            switch result {
                                case .failure(let error):
                                    SNLog("[SyncPushTokensJob] Failed to register due to error: \(error)")
                                
                                case .finished:
                                    Logger.warn("Recording push tokens locally. pushToken: \(redact(pushToken)), voipToken: \(redact(voipToken))")
                                    SNLog("[SyncPushTokensJob] Completed")
                                    UserDefaults.standard[.lastPushNotificationSync] = Date()

                                    Storage.shared.write { db in
                                        db[.lastRecordedPushToken] = pushToken
                                        db[.lastRecordedVoipToken] = voipToken
                                    }
                            }
                        }
                    )
                    .map { _ in () }
                    .eraseToAnyPublisher()
            }
            .subscribe(on: queue)
            .sinkUntilComplete(
                // We want to complete this job regardless of success or failure
                receiveCompletion: { _ in success(job, false, dependencies) }
            )
    }
    
    public static func run(uploadOnlyIfStale: Bool) {
        guard let job: Job = Job(
            variant: .syncPushTokens,
            behaviour: .runOnce,
            details: SyncPushTokensJob.Details(
                uploadOnlyIfStale: uploadOnlyIfStale
            )
        )
        else { return }
                                 
        SyncPushTokensJob.run(
            job,
            queue: DispatchQueue.global(qos: .default),
            success: { _, _, _ in },
            failure: { _, _, _, _ in },
            deferred: { _, _ in }
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
