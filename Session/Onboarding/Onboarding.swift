// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUtilitiesKit
import SessionMessagingKit
import SessionNetworkingKit

// MARK: - Cache

public extension Cache {
    static let onboarding: CacheConfig<OnboardingCacheType, OnboardingImmutableCacheType> = Dependencies.create(
        identifier: "onboarding",
        createInstance: { dependencies, _ in Onboarding.Cache(flow: .none, using: dependencies) },
        mutableInstance: { $0 },
        immutableInstance: { $0 }
    )
}

// MARK: - Log.Category

public extension Log.Category {
    static let onboarding: Log.Category = .create("Onboarding", defaultLevel: .info)
}

// MARK: - Onboarding

public enum Onboarding {
    public enum State: CustomStringConvertible {
        case noUser
        case noUserInvalidKeyPair
        case noUserInvalidSeedGeneration
        case missingName
        case completed
        
        // stringlint:ignore_contents
        public var description: String {
            switch self {
                case .noUser: return "No User"
                case .noUserInvalidKeyPair: return "No User Invalid Key Pair"
                case .noUserInvalidSeedGeneration: return "No User Invalid Seed Generation"
                case .missingName: return "Missing Name"
                case .completed: return "Completed"
            }
        }
    }
    
    public enum Flow: CaseIterable {
        case none
        case register
        case restore
        case devSettings
    }
    
    enum SeedSource {
        case qrCode
        case mnemonic
        
        var genericErrorMessage: String {
            switch self {
                case .qrCode: "qrNotRecoveryPassword".localized()
                case .mnemonic: "recoveryPasswordErrorMessageGeneric".localized()
            }
        }
    }
}

// MARK: - Onboarding.Cache

extension Onboarding {
    class Cache: OnboardingCacheType {
        private let dependencies: Dependencies
        public let id: UUID
        public let initialFlow: Onboarding.Flow
        public var state: State
        public var displayName: AsyncStream<String?> { displayNameStream.stream }
        private let completionSubject: CurrentValueSubject<Bool, Never> = CurrentValueSubject(false)
        
        public var seed: Data
        public var ed25519KeyPair: KeyPair
        public var x25519KeyPair: KeyPair
        public var userSessionId: SessionId
        public var useAPNS: Bool
        
        private var hasInitialDisplayName: Bool
        private var userProfileConfigMessage: ProcessedMessage?
        private var retrieveDisplayNameTask: Task<Void, Never>?
        private let displayNameStream: CurrentValueAsyncStream<String?> = CurrentValueAsyncStream(nil)
        
        public var onboardingCompletePublisher: AnyPublisher<Void, Never> {
            completionSubject
                .filter { $0 }
                .map { _ in () }
                .eraseToAnyPublisher()
        }
        
        // MARK: - Initialization
        
        init(flow: Onboarding.Flow, using dependencies: Dependencies) {
            self.dependencies = dependencies
            self.id = dependencies.randomUUID()
            self.initialFlow = flow
            
            /// Try to load the users `ed25519SecretKey` from the general cache and generate the key pairs from it
            let ed25519SecretKey: [UInt8] = dependencies[cache: .general].ed25519SecretKey
            let ed25519KeyPair: KeyPair = {
                guard
                    !ed25519SecretKey.isEmpty,
                    let ed25519Seed: Data = dependencies[singleton: .crypto].generate(
                        .ed25519Seed(ed25519SecretKey: ed25519SecretKey)
                    ),
                    let ed25519KeyPair: KeyPair = dependencies[singleton: .crypto].generate(
                        .ed25519KeyPair(seed: Array(ed25519Seed))
                    )
                else { return .empty }
                
                return ed25519KeyPair
            }()
            let x25519KeyPair: KeyPair = {
                guard
                    ed25519KeyPair != .empty,
                    let x25519PublicKey: [UInt8] = dependencies[singleton: .crypto].generate(
                        .x25519(ed25519Pubkey: ed25519KeyPair.publicKey)
                    ),
                    let x25519SecretKey: [UInt8] = dependencies[singleton: .crypto].generate(
                        .x25519(ed25519Seckey: ed25519KeyPair.secretKey)
                    )
                else { return .empty }
                
                return KeyPair(publicKey: x25519PublicKey, secretKey: x25519SecretKey)
            }()
            
            /// Retrieve the users `displayName` from `libSession` (the source of truth - if the `ed25519SecretKey` is
            /// empty then we don't have an account yet so don't want to try to access the invalid `libSession` cache)
            // TODO: [NETWORK REFACTOR] Need to update this to wait for `libSession to be initialised
            // TODO: [NETWORK REFACTOR] await dependencies.waitUntilInitialised(cache: .libSession)
            let displayName: String = (ed25519SecretKey.isEmpty ?
                "" :
                dependencies.mutate(cache: .libSession) { $0.profile }.name
            )
            
            let hasInitialDisplayName: Bool = !displayName.isEmpty
            
            self.ed25519KeyPair = ed25519KeyPair
            self.hasInitialDisplayName = hasInitialDisplayName
            self.x25519KeyPair = x25519KeyPair
            self.userSessionId = (x25519KeyPair != .empty ?
                SessionId(.standard, publicKey: x25519KeyPair.publicKey) :
                .invalid
            )
            self.state = {
                guard ed25519KeyPair != .empty else { return .noUser }
                guard x25519KeyPair != .empty else { return .noUserInvalidKeyPair }
                guard hasInitialDisplayName else { return .missingName }
                
                return .completed
            }()
            self.seed = Data()      /// Overwritten below
            self.useAPNS = false    /// Overwritten below
            
            /// Update the cached values depending on the `initialState`
            switch state {
                case .noUser, .noUserInvalidKeyPair, .noUserInvalidSeedGeneration:
                    /// Remove the `LibSession.Cache` just in case (to ensure no previous state remains)
                    dependencies.remove(cache: .libSession)
                    
                    /// Try to generate the identity data
                    guard
                        let finalSeedData: Data = dependencies[singleton: .crypto].generate(.randomBytes(16)),
                        let identity: (ed25519KeyPair: KeyPair, x25519KeyPair: KeyPair) = try? Identity.generate(
                            from: finalSeedData,
                            using: dependencies
                        )
                    else {
                        /// Seed or identity generation failed so leave the `Onboarding.Cache` in an invalid state for the UI to
                        /// recover somehow
                        self.state = .noUserInvalidSeedGeneration
                        return
                    }
                    
                    /// The identity data was successfully generated so store it for the onboarding process
                    self.state = .noUserInvalidKeyPair
                    self.seed = finalSeedData
                    self.ed25519KeyPair = identity.ed25519KeyPair
                    self.x25519KeyPair = identity.x25519KeyPair
                    self.userSessionId = SessionId(.standard, publicKey: identity.x25519KeyPair.publicKey)
                    
                case .missingName, .completed:
                    self.useAPNS = dependencies[defaults: .standard, key: .isUsingFullAPNs]
                    
                    /// If we are already in a completed state then updated the completion subject accordingly
                    if self.state == .completed {
                        self.completionSubject.send(true)
                    }
                    
                    /// If we know we are missing the name then we need to emit a non-null value to the `displayNameStream`
                    Task { [weak self] in
                        await self?.displayNameStream.send("")
                    }
            }
        }
        
        /// This initializer should only be used in the `DeveloperSettingsViewModel` when swapping between network service layers
        init(
            ed25519KeyPair: KeyPair,
            x25519KeyPair: KeyPair,
            displayName: String,
            using dependencies: Dependencies
        ) {
            self.dependencies = dependencies
            self.id = dependencies.randomUUID()
            self.state = .completed
            self.initialFlow = .devSettings
            self.seed = Data()
            self.ed25519KeyPair = ed25519KeyPair
            self.x25519KeyPair = x25519KeyPair
            self.userSessionId = SessionId(.standard, publicKey: x25519KeyPair.publicKey)
            self.useAPNS = dependencies[defaults: .standard, key: .isUsingFullAPNs]
            self.hasInitialDisplayName = !displayName.isEmpty
            
            Task { [weak self] in
                await self?.displayNameStream.send(displayName)
            }
        }
        
        deinit {
            Task { [displayNameStream] in
                await displayNameStream.finishCurrentStreams()
            }
        }
        
        // MARK: - Functions
        
        public func setSeedData(_ seedData: Data) throws {
            /// Generate the keys and store them
            let identity: (ed25519KeyPair: KeyPair, x25519KeyPair: KeyPair) = try Identity.generate(
                from: seedData,
                using: dependencies
            )
            self.seed = seedData
            self.ed25519KeyPair = identity.ed25519KeyPair
            self.x25519KeyPair = identity.x25519KeyPair
            self.userSessionId = SessionId(.standard, publicKey: identity.x25519KeyPair.publicKey)
            
            /// Kick off the request to get the display name
            retrieveDisplayNameTask?.cancel()
            retrieveDisplayNameTask = Task(priority: .userInitiated) { [weak self, userSessionId, dependencies] in
                /// **Note:** We trigger this as a "background poll" as doing so means the received messages will be
                /// processed immediately rather than async as part of a Job
                let poller: CurrentUserPoller = CurrentUserPoller(
                    pollerName: "Onboarding Poller", // stringlint:ignore
                    pollerQueue: Threading.pollerQueue,
                    pollerDestination: .swarm(userSessionId.hexString),
                    swarmDrainStrategy: .alwaysRandom,
                    namespaces: [.configUserProfile],
                    shouldStoreMessages: false,
                    logStartAndStopCalls: false,
                    customAuthMethod: Authentication.standard(
                        sessionId: userSessionId,
                        ed25519PublicKey: identity.ed25519KeyPair.publicKey,
                        ed25519SecretKey: identity.ed25519KeyPair.secretKey
                    ),
                    key: nil,
                    using: dependencies
                )
                guard !Task.isCancelled else { return }
                
                do {
                    let messages: [ProcessedMessage] = try await poller
                        .poll(forceSynchronousProcessing: true)
                        .response
                    
                    guard
                        !Task.isCancelled,
                        let targetMessage: ProcessedMessage = messages.last, /// Just in case there are multiple
                        case let .config(_, _, serverHash, serverTimestampMs, data, _) = targetMessage
                    else { return }
                    
                    /// In order to process the config message we need to create and load a `libSession` cache, but we don't
                    /// want to load this into memory at this stage in case the user cancels the onboarding process part way through
                    let cache: LibSession.Cache = LibSession.Cache(
                        userSessionId: userSessionId,
                        using: dependencies
                    )
                    cache.loadDefaultStateFor(
                        variant: .userProfile,
                        sessionId: userSessionId,
                        userEd25519SecretKey: identity.ed25519KeyPair.secretKey,
                        groupEd25519SecretKey: nil
                    )
                    _ = try cache.mergeConfigMessages(
                        swarmPublicKey: userSessionId.hexString,
                        messages: [
                            ConfigMessageReceiveJob.Details.MessageInfo(
                                namespace: .configUserProfile,
                                serverHash: serverHash,
                                serverTimestampMs: serverTimestampMs,
                                data: data
                            )
                        ]
                    )
                    
                    guard !Task.isCancelled else { return }
                    
                    /// Only store the `displayName` returned from the swarm if the user hasn't provided one in the display
                    /// name step (otherwise the user could enter a display name and have it immediately overwritten due to the
                    /// config request running slow)
                    if
                        self?.hasInitialDisplayName != true,
                        let displayName: String = cache.displayName,
                        !displayName.isEmpty
                    {
                        await self?.displayNameStream.send(displayName)
                    }
                    
                    self?.userProfileConfigMessage = targetMessage
                }
                catch {
                    Log.warn(.onboarding, "Failed to retrieve existing profile information due to error: \(error).")
                    
                    /// Always emit a value if we got a response (doesn't matter it it was a successful response or not, we just want to
                    /// finish loading)
                    await self?.displayNameStream.send(self?.displayNameStream.getCurrent() ?? "")
                }
            }
        }
        
        func setUseAPNS(_ useAPNS: Bool) {
            self.useAPNS = useAPNS
        }
        
        func setDisplayName(_ displayName: String) async {
            retrieveDisplayNameTask?.cancel()
            
            await displayNameStream.send(displayName)
        }
        
        func completeRegistration(onComplete: @escaping (@MainActor () -> Void)) {
            Task.detached(priority: .userInitiated) { [weak self, initialFlow, originalState = state, userSessionId, ed25519KeyPair, x25519KeyPair, useAPNS, userProfileConfigMessage, dependencies] in
                guard let self else { return }
                
                /// Cache the users session id (so we don't need to fetch it from the database every time)
                dependencies.mutate(cache: .general) {
                    $0.setSecretKey(ed25519SecretKey: ed25519KeyPair.secretKey)
                }
                
                /// If we had a proper `initialFlow` then create a new `libSession` cache for the user
                if initialFlow != .none {
                    dependencies.set(
                        cache: .libSession,
                        to: LibSession.Cache(
                            userSessionId: userSessionId,
                            using: dependencies
                        )
                    )
                }
                
                let displayName: String = (await displayNameStream.getCurrent() ?? "")
                try? await dependencies[singleton: .storage].writeAsync { [weak self] db in
                    /// Only update the identity/contact/Note to Self state if we have a proper `initialFlow`
                    if initialFlow != .none {
                        /// Store the user identity information
                        try Identity.store(db, ed25519KeyPair: ed25519KeyPair, x25519KeyPair: x25519KeyPair)
                        
                        /// Create a contact for the current user and set their approval/trusted statuses so they don't get weird behaviours
                        try Contact
                            .fetchOrCreate(db, id: userSessionId.hexString, using: dependencies)
                            .upsert(db)
                        try Contact
                            .filter(id: userSessionId.hexString)
                            .updateAll( /// Current user `Contact` record not synced so no need to use `updateAllAndConfig`
                                db,
                                Contact.Columns.isTrusted.set(to: true),    /// Always trust the current user
                                Contact.Columns.isApproved.set(to: true),
                                Contact.Columns.didApproveMe.set(to: true)
                            )
                        db.addContactEvent(id: userSessionId.hexString, change: .isTrusted(true))
                        db.addContactEvent(id: userSessionId.hexString, change: .isApproved(true))
                        db.addContactEvent(id: userSessionId.hexString, change: .didApproveMe(true))
                        
                        /// Load the initial `libSession` state (won't have been created on launch due to lack of ed25519 key)
                        let cachedProfile: Profile = dependencies.mutate(cache: .libSession) { cache in
                            cache.loadState(db)
                            
                            /// If we have a `userProfileConfigMessage` then we should try to handle it here as if we don't then
                            /// we won't even process it (because the hash may be deduped via another process)
                            if let userProfileConfigMessage: ProcessedMessage = userProfileConfigMessage {
                                try? cache.handleConfigMessages(
                                    db,
                                    swarmPublicKey: userSessionId.hexString,
                                    messages: ConfigMessageReceiveJob
                                        .Details(messages: [userProfileConfigMessage])
                                        .messages
                                )
                            }
                            
                            return cache.profile
                        }
                        
                        /// If we don't have the `Note to Self` thread then create it (not visible by default)
                        if (try? SessionThread.exists(db, id: userSessionId.hexString)) != nil {
                            try ThreadCreationContext.$isOnboarding.withValue(true) {
                                try SessionThread.upsert(
                                    db,
                                    id: userSessionId.hexString,
                                    variant: .contact,
                                    values: SessionThread.TargetValues(shouldBeVisible: .setTo(false)),
                                    using: dependencies
                                )
                            }
                        }
                        
                        /// Update the `displayName` if changed
                        if cachedProfile.name != displayName {
                            try Profile.updateIfNeeded(
                                db,
                                publicKey: userSessionId.hexString,
                                displayNameUpdate: .currentUserUpdate(displayName),
                                displayPictureUpdate: .none,
                                proUpdate: .none,
                                profileUpdateTimestamp: dependencies.dateNow.timeIntervalSince1970,
                                currentUserSessionIds: [userSessionId.hexString],
                                using: dependencies
                            )
                        }
                        
                        /// Emit observation events (_shouldn't_ be needed since this is happening during onboarding but
                        /// doesn't hurt just to be safe)
                        db.addEvent(useAPNS, forKey: .isUsingFullAPNs)
                    }
                    
                    /// Now that everything is saved we should update the `Onboarding.Cache` `state` to be `completed` (we do
                    /// this within the db write query because then `updateAllAndConfig` below will trigger a config sync which is
                    /// dependant on this `state` being updated)
                    self?.state = .completed
                    
                    /// We need to explicitly `updateAllAndConfig` the `shouldBeVisible` value to `false` for new accounts otherwise it
                    /// won't actually get synced correctly and could result in linking a second device and having the 'Note to Self' conversation incorrectly
                    /// being visible
                    if initialFlow == .register {
                        _ = try? SessionThread.update(
                            db,
                            id: userSessionId.hexString,
                            values: SessionThread.TargetValues(
                                shouldBeVisible: .setTo(false)
                            ),
                            using: dependencies
                        )
                    }
                }
                
                /// No need to show the seed again if the user is restoring (just in case only set the value if it hasn't already
                /// been set - this will prevent us from unintentionally re-showing the seed banner)
                if initialFlow == .register || initialFlow == .restore {
                    dependencies.setAsync(.hasViewedSeed, (initialFlow == .restore))
                }
                
                /// Now that the onboarding process is completed we can store the `UserMetadata` for the Share and Notification
                /// extensions (prior to this point the account is in an invalid state so they can't be used)
                do {
                    try dependencies[singleton: .extensionHelper].saveUserMetadata(
                        sessionId: userSessionId,
                        ed25519SecretKey: ed25519KeyPair.secretKey,
                        unreadCount: 0
                    )
                } catch { Log.error(.onboarding, "Falied to save user metadata: \(error)") }
                
                /// Store whether the user wants to use APNS
                dependencies[defaults: .standard, key: .isUsingFullAPNs] = useAPNS
                
                /// Log the resolution
                switch (initialFlow, originalState) {
                    case (.none, _), (.devSettings, _): break
                    case (.register, _): Log.info(.onboarding, "Registration completed")
                    case (.restore, .missingName): Log.info(.onboarding, "Missing name replaced")
                    case (.restore, _): Log.info(.onboarding, "Restore account completed")
                }
                
                /// Send an event indicating that registration is complete
                completionSubject.send(true)
                
                await MainActor.run {
                    onComplete()
                }
            }
        }
    }
}

// MARK: - OnboardingCacheType

/// This is a read-only version of the Cache designed to avoid unintentionally mutating the instance in a non-thread-safe way
public protocol OnboardingImmutableCacheType: ImmutableCacheType {
    var id: UUID { get }
    var state: Onboarding.State { get }
    var initialFlow: Onboarding.Flow { get }
    var displayName: AsyncStream<String?> { get }
    
    var seed: Data { get }
    var ed25519KeyPair: KeyPair { get }
    var x25519KeyPair: KeyPair { get }
    var userSessionId: SessionId { get }
    var useAPNS: Bool { get }
    
    var onboardingCompletePublisher: AnyPublisher<Void, Never> { get }
    
    func setDisplayName(_ displayName: String) async
}

public protocol OnboardingCacheType: OnboardingImmutableCacheType, MutableCacheType {
    var id: UUID { get }
    var state: Onboarding.State { get }
    var initialFlow: Onboarding.Flow { get }
    var displayName: AsyncStream<String?> { get }
    
    var seed: Data { get }
    var ed25519KeyPair: KeyPair { get }
    var x25519KeyPair: KeyPair { get }
    var userSessionId: SessionId { get }
    var useAPNS: Bool { get }
    
    var onboardingCompletePublisher: AnyPublisher<Void, Never> { get }
    
    func setSeedData(_ seedData: Data) throws
    func setUseAPNS(_ useAPNS: Bool)
    func setDisplayName(_ displayName: String) async
    
    /// Complete the registration process storing the created/updated user state in the database and creating
    /// the `libSession` state if needed
    ///
    /// **Note:** The `onComplete` callback will be run on the main thread
    func completeRegistration(onComplete: @escaping (@MainActor () -> Void))
}

public extension OnboardingCacheType {
    func completeRegistration() { completeRegistration(onComplete: {}) }
}
