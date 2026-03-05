// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import PushKit
import GRDB
import SessionMessagingKit
import SignalUtilitiesKit
import SessionUtilitiesKit

// MARK: - Singleton

public extension Singleton {
    static let pushRegistrationManager: SingletonConfig<PushRegistrationManager> = Dependencies.create(
        identifier: "pushRegistrationManager",
        createInstance: { dependencies, _ in PushRegistrationManager(using: dependencies) }
    )
}

// MARK: - PushRegistrationManager

public class PushRegistrationManager: NSObject, PKPushRegistryDelegate {
    private let dependencies: Dependencies
    private let tokenState: PushTokenState = PushTokenState()
    private var voipRegistry: PKPushRegistry?

    // MARK: - Initialization

    fileprivate init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        
        super.init()
    }

    // MARK: - Public interface

    public func requestPushTokens() async throws -> (pushToken: String, voipToken: String) {
        /// Notification settings must be registered before the OS will return a push token
        await dependencies[singleton: .notificationsManager].registerSystemNotificationSettings()
        
        #if targetEnvironment(simulator)
        throw PushRegistrationError.pushNotSupported(description: "Push not supported on simulators")
        #else
        async let pushToken: String = requestVanillaToken()
        async let voipToken: String? = requestVoipToken()
        
        return try await (pushToken, voipToken ?? "")
        #endif
    }

    // MARK: - Vanilla push token

    /// Vanilla push token is obtained from the system via AppDelegate
    public func didReceiveVanillaPushToken(_ tokenData: Data) {
        Task { await tokenState.resolveVanilla(.success(tokenData)) }
    }

    /// Vanilla push token is obtained from the system via AppDelegate
    public func didFailToReceiveVanillaPushToken(error: Error) {
        Task { await tokenState.resolveVanilla(.failure(error)) }
    }

    // MARK: - Helpers

    /// When users have disabled notifications and background fetch, the system hangs when returning a push token.
    ///
    /// More specifically, after registering for remote notification, the app delegate calls neither
    /// `didFailToRegisterForRemoteNotificationsWithError` nor `didRegisterForRemoteNotificationsWithDeviceToken`
    /// This behavior is identical to what you'd see if we hadn't previously registered for user notification settings, though in this case
    /// we've verified that we *have* properly registered notification settings.
    private var isSusceptibleToFailedPushRegistration: Bool {
        get async {
            let backgroundRefreshDenied: Bool = await MainActor.run {
                UIApplication.shared.backgroundRefreshStatus == .denied
            }
            guard backgroundRefreshDenied else { return false }

            let settings: UNNotificationSettings = await withCheckedContinuation { continuation in
                UNUserNotificationCenter.current().getNotificationSettings {
                    continuation.resume(returning: $0)
                }
            }
            
            return (settings.authorizationStatus == .denied)
        }
    }

    private func requestVanillaToken() async throws -> String {
        let isSusceptible: Bool = await isSusceptibleToFailedPushRegistration
        
        /// Sometimes registration can just take a while, if we're not on a device known to be susceptible to push registration failure,
        /// then we want to give it a slightly longer timeout to give them more of a chance to successfully register
        let timeout: DispatchTimeInterval = (isSusceptible ? .seconds(10) : .seconds(20))
        
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { [weak self] in
                guard let self else {
                    throw PushRegistrationError.assertionError(description: "self deallocated")
                }

                let tokenData: Data = try await tokenState.awaitVanilla {
                    /// Registering for remote notifications must happen on the main thread
                    await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
                }

                if isSusceptible {
                    /// Sentinal in case this bug is fixed
                    Log.debug(.syncPushTokensJob, "Device was unexpectedly able to complete push registration even though it was susceptible to failure.")
                }
                
                return tokenData.toHexString()
            }

            group.addTask {
                try await Task.sleep(for: timeout)
                
                if isSusceptible {
                    throw PushRegistrationError.pushNotSupported(
                        description: "Device configuration disallows push notifications" // stringlint:ignore
                    )
                }
                
                throw PushRegistrationError.timeout
            }

            /// Whichever finishes first (token or timeout) wins; cancel the other
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
    
    public func createVoipRegistryIfNecessary() {
        guard voipRegistry == nil else { return }
        
        let voipRegistry = PKPushRegistry(queue: nil)
        self.voipRegistry = voipRegistry
        voipRegistry.desiredPushTypes = [.voIP]
        voipRegistry.delegate = self
    }
    
    private func requestVoipToken() async throws -> String? {
        createVoipRegistryIfNecessary()

        /// If PushKit already cached a token, return it immediately without waiting
        if let existingToken = voipRegistry?.pushToken(for: .voIP) {
            Log.info(.syncPushTokensJob, "Using pre-registered voIP token")
            return existingToken.toHexString()
        }
        
        guard self.voipRegistry != nil else {
            Log.error(.syncPushTokensJob, "Failed to initialize voipRegistry")
            throw PushRegistrationError.assertionError(description: "failed to initialize voipRegistry")
        }

        let data = try await tokenState.awaitVoip()
        Log.info(.syncPushTokensJob, "Successfully registered for voip push notifications")
        return data?.toHexString()
    }
    
    // MARK: - PKPushRegistryDelegate
    
    public func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        Log.assert(type == .voIP)
        Log.assert(pushCredentials.type == .voIP)

        Task { await tokenState.resolveVoip(.success(pushCredentials.token)) }
    }
    
    // NOTE: This function MUST report an incoming call.
    public func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType) {
        Log.info(.calls, "Receive new voip notification.")
        Log.assert(dependencies[singleton: .appContext].isMainApp)
        Log.assert(type == .voIP)
        let payload = payload.dictionaryPayload
        
        guard
            let uuid: String = payload[VoipPayloadKey.uuid.rawValue] as? String,
            let caller: String = payload[VoipPayloadKey.caller.rawValue] as? String,
            let timestampMs: UInt64 = payload[VoipPayloadKey.timestamp.rawValue] as? UInt64,
            let contactName: String = payload[VoipPayloadKey.contactName.rawValue] as? String,
            TimestampUtils.isWithinOneMinute(timestampMs: timestampMs)
        else {
            dependencies[singleton: .callManager].reportFakeCall(info: "Missing payload data") // stringlint:ignore
            return
        }
        
        let call: SessionCall = SessionCall(
            for: caller,
            contactName: contactName,
            uuid: uuid,
            mode: .answer,
            using: dependencies
        )
        
        Log.info(.calls, "Calls created with UUID: \(uuid), caller: \(caller), contactName: \(contactName)")
        
        call.reportIncomingCallIfNeeded { [dependencies] error in
            if let error = error {
                Log.error(.calls, "Failed to report incoming call to CallKit due to error: \(error)")
                return
            }
            
            Log.info(.calls, "Succeeded to report incoming call to CallKit")
            Task.detached(priority: .userInitiated) { [dependencies] in
                await dependencies[singleton: .storage].resumeDatabaseAccess()
                await dependencies[singleton: .network].resumeNetworkAccess()
                await dependencies[singleton: .jobRunner].appDidBecomeActive()
                
                /// Wait for the app to be ready before starting the poller
                ///
                /// **Note:** Just start 1-1 poller so that it won't wait for polling group messages
                await dependencies[singleton: .appReadiness].isReady()
                
                await dependencies[singleton: .currentUserPoller].startIfNeeded(
                    forceStartInBackground: true
                )
            }
        }
    }
}

// MARK: - PushTokenState

private actor PushTokenState {
    private var vanillaRegistrationStarted: Bool = false
    private var vanillaContinuations: [CheckedContinuation<Data, Error>] = []
    private var voipContinuations: [CheckedContinuation<Data?, Error>] = []
    
    // MARK: - Push
    
    /// Suspends the caller until the vanilla push token is delivered (or the task is cancelled) - only triggers
    /// `UIApplication.registerForRemoteNotifications()` on the first call; subsequent concurrent callers queue onto
    /// the same in-flight registration
    func awaitVanilla(register: @escaping () async -> Void) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                /// Queue this caller regardless (all queued continuations are resolved together)
                vanillaContinuations.append(continuation)

                /// Only start the OS registration once per round-trip
                guard !vanillaRegistrationStarted else { return }
                
                vanillaRegistrationStarted = true
                
                Task { await register() }
            }
        } onCancel: {
            /// Resume all waiters with CancellationError so no continuation ever leaks
            Task { await self.resolveVanilla(.failure(CancellationError())) }
        }
    }

    func resolveVanilla(_ result: Result<Data, Error>) {
        vanillaRegistrationStarted = false
        
        let pending: [CheckedContinuation<Data, Error>] = vanillaContinuations
        vanillaContinuations = []
        
        pending.forEach { $0.resume(with: result) }
    }
    
    // MARK: - VoIP
    
    func awaitVoip() async throws -> Data? {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    voipContinuations.append(continuation)
                }
            } onCancel: {
                Task { await self.resolveVoip(.failure(CancellationError())) }
            }
        }

        func resolveVoip(_ result: Result<Data, Error>) {
            let pending: [CheckedContinuation<Data?, any Error>] = voipContinuations
            voipContinuations = []
            
            pending.forEach {
                switch result {
                    case .success(let data): $0.resume(returning: data)
                    case .failure(let error): $0.resume(throwing: error)
                }
            }
        }
}

// MARK: - PushRegistrationError

public enum PushRegistrationError: Error {
    case assertionError(description: String)
    case pushNotSupported(description: String)
    case timeout
    case publisherNoLongerExists
}
