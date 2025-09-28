// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUtilitiesKit
import SessionMessagingKit
import SessionNetworkingKit

// MARK: - Cache

public extension Singleton {
    static let onboarding: SingletonConfig<OnboardingManagerType> = Dependencies.create(
        identifier: "onboarding",
        createInstance: { dependencies, _ in Onboarding.Manager(flow: .none, using: dependencies) }
    )
}

// MARK: - Log.Category

public extension Log.Category {
    static let onboarding: Log.Category = .create("Onboarding", defaultLevel: .info)
}

// MARK: - Onboarding

public enum Onboarding {
    public enum State: CustomStringConvertible {
        case unknown
        case noUser
        case noUserInvalidKeyPair
        case noUserInvalidSeedGeneration
        case missingName
        case completed
        
        // stringlint:ignore_contents
        public var description: String {
            switch self {
                case .unknown: return "Unknown"
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

// MARK: - Onboarding.Manager

extension Onboarding {
    actor Manager: OnboardingManagerType {
        private let dependencies: Dependencies
        nonisolated public let syncState: OnboardingManagerSyncState = OnboardingManagerSyncState()
        public let id: UUID
        public let initialFlow: Onboarding.Flow
        public var state: AsyncStream<State> { stateStream.stream }
        public var displayName: AsyncStream<String?> { displayNameStream.stream }
        
        public var seed: Data = Data()
        public var ed25519KeyPair: KeyPair = .empty
        public var x25519KeyPair: KeyPair = .empty
        public var userSessionId: SessionId = .invalid
        public var useAPNS: Bool = false
        
        private var hasInitialDisplayName: Bool = false
        private var userProfileConfigMessage: ProcessedMessage?
        private var retrieveDisplayNameTask: Task<Void, Never>?
        private let stateStream: CurrentValueAsyncStream<State> = CurrentValueAsyncStream(.unknown)
        private let displayNameStream: CurrentValueAsyncStream<String?> = CurrentValueAsyncStream(nil)
        
        // MARK: - Initialization
        
        init(flow: Onboarding.Flow, using dependencies: Dependencies) {
            self.dependencies = dependencies
            self.id = dependencies.randomUUID()
            self.initialFlow = flow
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
            self.initialFlow = .devSettings
            self.seed = Data()
            self.ed25519KeyPair = ed25519KeyPair
            self.x25519KeyPair = x25519KeyPair
            self.userSessionId = SessionId(.standard, publicKey: x25519KeyPair.publicKey)
            self.useAPNS = dependencies[defaults: .standard, key: .isUsingFullAPNs]
            self.hasInitialDisplayName = !displayName.isEmpty
            
            Task { [self] in
                syncState.update(state: .completed)
                await stateStream.send(.completed)
                await displayNameStream.send(displayName)
            }
        }
        
        deinit {
            Task { [stateStream, displayNameStream] in
                await stateStream.finishCurrentStreams()
                await displayNameStream.finishCurrentStreams()
            }
        }
        
        // MARK: - Functions
        
        public func loadInitialState() async throws {
            /// Try to load the users `ed25519SecretKey` from the general cache and generate the key pairs from it
            let ed25519SecretKey: [UInt8] = dependencies[cache: .general].ed25519SecretKey
            ed25519KeyPair = {
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
            x25519KeyPair = {
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
            
            /// Retrieve the users `displayName` from `libSession` (the source of truth)
            await displayNameStream.send(dependencies.mutate(cache: .libSession) { $0.profile }.name)
            hasInitialDisplayName = await !(displayNameStream.currentValue ?? "").isEmpty
            userSessionId = (x25519KeyPair != .empty ?
                SessionId(.standard, publicKey: x25519KeyPair.publicKey) :
                .invalid
            )
            
            let expectedState: Onboarding.State = {
                guard ed25519KeyPair != .empty else { return .noUser }
                guard x25519KeyPair != .empty else { return .noUserInvalidKeyPair }
                guard hasInitialDisplayName else { return .missingName }
                
                return .completed
            }()
            
            /// Update the cached values depending on the `initialState`
            switch expectedState {
                case .unknown, .noUser, .noUserInvalidKeyPair, .noUserInvalidSeedGeneration:
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
                        syncState.update(state: .noUserInvalidSeedGeneration)
                        await stateStream.send(.noUserInvalidSeedGeneration)
                        return
                    }
                    
                    /// The identity data was successfully generated so store it for the onboarding process
                    seed = finalSeedData
                    ed25519KeyPair = identity.ed25519KeyPair
                    x25519KeyPair = identity.x25519KeyPair
                    userSessionId = SessionId(.standard, publicKey: identity.x25519KeyPair.publicKey)
                    await displayNameStream.send(nil)
                    syncState.update(state: .noUserInvalidKeyPair)
                    await stateStream.send(.noUserInvalidKeyPair)
                    
                case .missingName, .completed:
                    useAPNS = dependencies[defaults: .standard, key: .isUsingFullAPNs]
                    syncState.update(state: expectedState)
                    await stateStream.send(expectedState)
            }
        }
        
        public func setSeedData(_ seedData: Data) throws {
            /// Generate the keys and store them
            let identity: (ed25519KeyPair: KeyPair, x25519KeyPair: KeyPair) = try Identity.generate(
                from: seedData,
                using: dependencies
            )
            seed = seedData
            ed25519KeyPair = identity.ed25519KeyPair
            x25519KeyPair = identity.x25519KeyPair
            userSessionId = SessionId(.standard, publicKey: identity.x25519KeyPair.publicKey)
            
            /// Kick off the request to get the display name
            retrieveDisplayNameTask?.cancel()
            retrieveDisplayNameTask = Task(priority: .userInitiated) { [weak self, userSessionId, dependencies] in
                /// **Note:** We trigger this as a "background poll" as doing so means the received messages will be
                /// processed immediately rather than async as part of a Job
                let poller: CurrentUserPoller = CurrentUserPoller(
                    pollerName: "Onboarding Poller", // stringlint:ignore
                    destination: .swarm(userSessionId.hexString),
                    swarmDrainStrategy: .alwaysRandom,
                    namespaces: [.configUserProfile],
                    failureCount: 0,
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
                    
                    /// In order to process the config message we need to create and load a `libSession` cache, but we don't want to load this into
                    /// memory at this stage in case the user cancels the onboarding process part way through
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
                    try cache.unsafeDirectMergeConfigMessage(
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
                        await self?.hasInitialDisplayName != true,
                        let displayName: String = cache.displayName,
                        !displayName.isEmpty
                    {
                        await self?.displayNameStream.send(displayName)
                    }
                    
                    await self?.setUserProfileConfigMessage(targetMessage)
                }
                catch {
                    Log.warn(.onboarding, "Failed to retrieve existing profile information due to error: \(error).")
                    
                    /// Always emit a value if we got a response (doesn't matter it it was a successful response or not, we just want to
                    /// finish loading)
                    await self?.displayNameStream.send(self?.displayNameStream.currentValue)
                }
            }
        }
        
        func setUseAPNS(_ useAPNS: Bool) async {
            self.useAPNS = useAPNS
        }
        
        func setDisplayName(_ displayName: String) async {
            retrieveDisplayNameTask?.cancel()
            
            await displayNameStream.send(displayName)
        }
        
        private func setUserProfileConfigMessage(_ userProfileConfigMessage: ProcessedMessage) {
            self.userProfileConfigMessage = userProfileConfigMessage
        }
        
        func completeRegistration() async {
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
            
            let originalState: State = await stateStream.currentValue
            let displayName: String = (await displayNameStream.currentValue ?? "")
            try? await dependencies[singleton: .storage].writeAsync { [self] db in
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
                    
                    /// Create the 'Note to Self' thread (not visible by default)
                    try SessionThread.upsert(
                        db,
                        id: userSessionId.hexString,
                        variant: .contact,
                        values: SessionThread.TargetValues(shouldBeVisible: .setTo(false)),
                        using: dependencies
                    )
                    
                    /// Load the initial `libSession` state (won't have been created on launch due to lack of ed25519 key)
                    try dependencies.mutate(cache: .libSession) { cache in
                        try cache.loadState(db, userEd25519SecretKey: ed25519KeyPair.secretKey)
                        
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
                        else {
                            /// We need to explicitly set the `priority` value to `hiddenPriority` for new accounts
                            /// otherwise it won't actually get synced correctly and could result in linking a second device and
                            /// having the 'Note to Self' conversation incorrectly being visible
                            try? LibSession.updateNoteToSelf(
                                db,
                                priority: LibSession.hiddenPriority,
                                using: dependencies
                            )
                        }
                        
                        /// Update the `displayName` and trigger a dump/push of the config
                        try? cache.performAndPushChange(db, for: .userProfile) {
                            try? cache.updateProfile(displayName: displayName)
                        }
                    }
                    
                    /// Clear the `lastNameUpdate` timestamp and forcibly set the `displayName` provided
                    /// during the onboarding step (we do this after handling the config message because we want
                    /// the value provided during onboarding to superseed any retrieved from the config)
                    try Profile
                        .fetchOrCreate(db, id: userSessionId.hexString)
                        .upsert(db)
                    try Profile
                        .filter(id: userSessionId.hexString)
                        .updateAll(db, Profile.Columns.lastNameUpdate.set(to: nil))
                    try Profile.updateIfNeeded(
                        db,
                        publicKey: userSessionId.hexString,
                        displayNameUpdate: .currentUserUpdate(displayName),
                        displayPictureUpdate: .none,
                        sentTimestamp: dependencies.dateNow.timeIntervalSince1970,
                        using: dependencies
                    )
                    
                    /// Emit observation events (_shouldn't_ be needed since this is happening during onboarding but
                    /// doesn't hurt just to be safe)
                    db.addEvent(useAPNS, forKey: .isUsingFullAPNs)
                }
            }
            
            /// No need to show the seed again if the user is restoring
            await dependencies.set(.hasViewedSeed, (initialFlow == .restore))
            
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
            
            /// Now flag the state as completed
            syncState.update(state: .completed)
            await stateStream.send(.completed)
            
            /// Perform a config sync if needed (this needs to be done for new accounts to ensure the initial state is synced correctly)
            try? await dependencies[singleton: .storage].writeAsync { [self] db in
                ConfigurationSyncJob.enqueue(db, swarmPublicKey: userSessionId.hexString, using: dependencies)
            }
        }
    }
}

// MARK: - OnboardingManagerSyncState

/// We manually handle thread-safety using the `NSLock` so can ensure this is `Sendable`
public final class OnboardingManagerSyncState: @unchecked Sendable {
    private let lock = NSLock()
    private var _state: Onboarding.State = .unknown
    
    public var state: Onboarding.State { lock.withLock { _state } }

    func update(state: Onboarding.State) {
        lock.withLock { self._state = state }
    }
}

// MARK: - OnboardingManagerType

public protocol OnboardingManagerType: Actor {
    @available(*, deprecated, message: "Should try to refactor the code to use proper async/await")
    nonisolated var syncState: OnboardingManagerSyncState { get }
    
    var id: UUID { get }
    var initialFlow: Onboarding.Flow { get }
    var state: AsyncStream<Onboarding.State> { get }
    var displayName: AsyncStream<String?> { get }
    
    var seed: Data { get }
    var ed25519KeyPair: KeyPair { get }
    var x25519KeyPair: KeyPair { get }
    var userSessionId: SessionId { get }
    var useAPNS: Bool { get }
    
    func loadInitialState() async throws
    func setSeedData(_ seedData: Data) async throws
    func setUseAPNS(_ useAPNS: Bool) async
    func setDisplayName(_ displayName: String) async
    
    /// Complete the registration process storing the created/updated user state in the database and creating
    /// the `libSession` state if needed
    func completeRegistration() async
}
