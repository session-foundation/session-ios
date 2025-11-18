// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionUIKit
import SessionNetworkingKit
import SessionUtilitiesKit

// MARK: - Singleton

public extension Singleton {
    static let sessionProManager: SingletonConfig<SessionProManagerType> = Dependencies.create(
        identifier: "sessionProManager",
        createInstance: { dependencies in SessionProManager(using: dependencies) }
    )
}

// MARK: - SessionPro

public enum SessionPro {
    public static var CharacterLimit: Int { SESSION_PROTOCOL_PRO_STANDARD_CHARACTER_LIMIT }
    public static var ProCharacterLimit: Int { SESSION_PROTOCOL_PRO_HIGHER_CHARACTER_LIMIT }
    public static var PinnedConversationLimit: Int { SESSION_PROTOCOL_PRO_STANDARD_PINNED_CONVERSATION_LIMIT }
}

// MARK: - SessionProManager

public actor SessionProManager: SessionProManagerType {
    private let dependencies: Dependencies
    nonisolated private let syncState: SessionProManagerSyncState
    private var isRefreshingState: Bool = false
    private var proStatusObservationTask: Task<Void, Never>?
    public var rotatingKeyPair: KeyPair?
    public var proFeatures: SessionPro.Features = .none
    
    nonisolated private let backendUserProStatusStream: CurrentValueAsyncStream<Network.SessionPro.BackendUserProStatus?> = CurrentValueAsyncStream(nil)
    nonisolated private let proProofStream: CurrentValueAsyncStream<Network.SessionPro.ProProof?> = CurrentValueAsyncStream(nil)
    
    nonisolated public var currentUserCurrentRotatingKeyPair: KeyPair? { syncState.rotatingKeyPair }
    nonisolated public var currentUserCurrentBackendProStatus: Network.SessionPro.BackendUserProStatus? {
        syncState.backendUserProStatus
    }
    nonisolated public var currentUserIsCurrentlyPro: Bool { syncState.backendUserProStatus == .active }
    nonisolated public var currentUserCurrentProProof: Network.SessionPro.ProProof? { syncState.proProof }
    nonisolated public var currentUserIsPro: AsyncStream<Bool> {
        backendUserProStatusStream.stream
            .map { $0 == .active }
            .asAsyncStream()
    }
    nonisolated public var characterLimit: Int {
        (currentUserIsCurrentlyPro ? SessionPro.ProCharacterLimit : SessionPro.CharacterLimit)
    }
    
    nonisolated public var backendUserProStatus: AsyncStream<Network.SessionPro.BackendUserProStatus?> {
        backendUserProStatusStream.stream
    }
    nonisolated public var proProof: AsyncStream<Network.SessionPro.ProProof?> { proProofStream.stream }
    
    // MARK: - Initialization
    
    public init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.syncState = SessionProManagerSyncState(using: dependencies)
        
        Task {
            await updateWithLatestFromUserConfig()
            await startProStatusObservations()
            
            /// Kick off a refresh so we know we have the latest state (if it's the main app)
            if dependencies[singleton: .appContext].isMainApp {
                try? await refreshProState()
            }
        }
    }
    
    deinit {
        proStatusObservationTask?.cancel()
    }
    
    // MARK: - Functions
    
    nonisolated public func numberOfCharactersLeft(for content: String) -> Int {
        let features: SessionPro.FeaturesForMessage = features(for: content)
        
        switch features.status {
            case .utfDecodingError:
                /// If we got a decoding error then fallback
                Log.error(.sessionPro, "Failed to decode content length due to error: \(features.error ?? "Unknown error")")
                return (characterLimit - content.utf16.count)
                
            case .success, .exceedsCharacterLimit: return (characterLimit - features.codePointCount)
        }
    }
    
    nonisolated public func proStatus<I: DataProtocol>(
        for proof: Network.SessionPro.ProProof?,
        verifyPubkey: I?,
        atTimestampMs timestampMs: UInt64
    ) -> SessionPro.ProStatus {
        guard let proof: Network.SessionPro.ProProof else { return .none }
        
        var cProProof: session_protocol_pro_proof = proof.libSessionValue
        let cVerifyPubkey: [UInt8] = (verifyPubkey.map { Array($0) } ?? [])
        
        return SessionPro.ProStatus(
            session_protocol_pro_proof_status(
                &cProProof,
                cVerifyPubkey,
                cVerifyPubkey.count,
                timestampMs,
                nil
            )
        )
    }
    
    nonisolated public func proProofIsActive(
        for proof: Network.SessionPro.ProProof?,
        atTimestampMs timestampMs: UInt64
    ) -> Bool {
        guard let proof: Network.SessionPro.ProProof else { return false }
        
        var cProProof: session_protocol_pro_proof = proof.libSessionValue
        
        return session_protocol_pro_proof_is_active(&cProProof, timestampMs)
    }
    
    nonisolated public func features(for message: String, features: SessionPro.Features) -> SessionPro.FeaturesForMessage {
        guard let cMessage: [CChar] = message.cString(using: .utf8) else {
            return SessionPro.FeaturesForMessage.invalidString
        }
        
        return SessionPro.FeaturesForMessage(
            session_protocol_pro_features_for_utf8(
                cMessage,
                (cMessage.count - 1),  /// Need to `- 1` to avoid counting the null-termination character
                features.libSessionValue
            )
        )
    }
    
    nonisolated public func attachProInfoIfNeeded(message: Message) -> Message {
        let featuresForMessage: SessionPro.FeaturesForMessage = features(
            for: ((message as? VisibleMessage)?.text ?? ""),
            features: (syncState.proFeatures ?? .none)
        )
        
        /// We only want to attach the `proFeatures` and `proProof` if a pro feature is _actually_ used
        guard
            featuresForMessage.status == .success,
            featuresForMessage.features != .none,
            let proof: Network.SessionPro.ProProof = syncState.proProof
        else {
            if featuresForMessage.status != .success {
                Log.error(.sessionPro, "Failed to get features for outgoing message due to error: \(featuresForMessage.error ?? "Unknown error")")
            }
            return message
        }
        
        let updatedMessage: Message = message
        updatedMessage.proFeatures = featuresForMessage.features
        updatedMessage.proProof = proof
        
        return updatedMessage
    }
    
    public func updateWithLatestFromUserConfig() async {
        if #available(iOS 16.0, *) {
            do { try await dependencies.waitUntilInitialised(cache: .libSession) }
            catch { return Log.error(.sessionPro, "Failed to wait until libSession initialised: \(error)") }
        }
        else {
            /// iOS 15 doesn't support dependency observation so work around it with a loop
            while true {
                try? await Task.sleep(for: .milliseconds(500))
                
                /// If `libSession` has data we can break
                if !dependencies[cache: .libSession].isEmpty {
                    break
                }
            }
        }
        
        /// Get the cached pro state from libSession
        let (proConfig, profile): (SessionPro.ProConfig?, Profile) = dependencies.mutate(cache: .libSession) {
            ($0.proConfig, $0.profile)
        }
        
        let rotatingKeyPair: KeyPair? = try? proConfig.map { config in
            guard config.rotatingPrivateKey.count >= 32 else { return nil }
            
            return try dependencies[singleton: .crypto].tryGenerate(
                .ed25519KeyPair(seed: config.rotatingPrivateKey.prefix(upTo: 32))
            )
        }
        
        /// Update the `syncState` first (just in case an update triggered from the async state results in something accessing the
        /// sync state)
        let proStatus: Network.SessionPro.BackendUserProStatus = {
            guard let proof: Network.SessionPro.ProProof = proConfig?.proProof else {
                return .neverBeenPro
            }
            
            let proofIsActive: Bool = proProofIsActive(
                for: proof,
                atTimestampMs: dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
            )
            return (proofIsActive ? .active : .expired)
        }()
        syncState.update(
            rotatingKeyPair: .set(to: rotatingKeyPair),
            backendUserProStatus: .set(to: proStatus),
            proProof: .set(to: proConfig?.proProof),
            proFeatures: .set(to: profile.proFeatures)
        )
        
        /// Then update the async state and streams
        self.rotatingKeyPair = rotatingKeyPair
        self.proFeatures = profile.proFeatures
        await self.proProofStream.send(proConfig?.proProof)
        await self.backendUserProStatusStream.send(proStatus)
    }
    
    @discardableResult @MainActor public func showSessionProCTAIfNeeded(
        _ variant: ProCTAModal.Variant,
        dismissType: Modal.DismissType,
        beforePresented: (() -> Void)?,
        afterClosed: (() -> Void)?,
        presenting: ((UIViewController) -> Void)?
    ) -> Bool {
        guard syncState.dependencies[feature: .sessionProEnabled] else { return false }
        
        switch variant {
            case .groupLimit: break /// The `groupLimit` CTA can be shown for Session Pro users as well
            default:
                guard syncState.backendUserProStatus != .active else { return false }
                
                break
        }
        
        beforePresented?()
        let sessionProModal: ModalHostingViewController = ModalHostingViewController(
            modal: ProCTAModal(
                variant: variant,
                dataManager: syncState.dependencies[singleton: .imageDataManager],
                sessionProUIManager: self,
                dismissType: dismissType,
                afterClosed: afterClosed
            )
        )
        presenting?(sessionProModal)
        
        return true
    }
    
    public func upgradeToPro(completion: ((_ result: Bool) -> Void)?) async {
        // TODO: [PRO] Need to actually implement this
        dependencies.set(feature: .mockCurrentUserSessionProBackendStatus, to: .active)
        await backendUserProStatusStream.send(.active)
        completion?(true)
    }
    
    // MARK: - Pro State Management
    
    public func refreshProState() async throws {
        /// No point refreshing the state if there is a refresh in progress
        guard !isRefreshingState else { return }
        
        isRefreshingState = true
        
        // FIXME: Await network connectivity when the refactored networking is merged
        let request = try? Network.SessionPro.getProDetails(
            masterKeyPair: try dependencies[singleton: .crypto].tryGenerate(.sessionProMasterKeyPair()),
            using: dependencies
        )
        // FIXME: Make this async/await when the refactored networking is merged
        let response: Network.SessionPro.GetProDetailsResponse = try await request
            .send(using: dependencies)
            .values
            .first(where: { _ in true })?.1 ?? { throw NetworkError.invalidResponse }()
        
        guard response.header.errors.isEmpty else {
            let errorString: String = response.header.errors.joined(separator: ", ")
            Log.error(.sessionPro, "Failed to retrieve pro details due to error(s): \(errorString)")
            throw NetworkError.explicit(errorString)
        }
        
        // TODO: [PRO] Need to add an observable event for the pro status
        syncState.update(backendUserProStatus: .set(to: response.status))
        await self.backendUserProStatusStream.send(response.status)
        
        switch response.status {
            case .active:
                try await refreshProProofIfNeeded(
                    accessExpiryTimestampMs: response.expiryTimestampMs,
                    autoRenewing: response.autoRenewing,
                    status: response.status
                )
                
            case .neverBeenPro: try await clearProProof()
            case .expired: try await clearProProof()
        }
        
        isRefreshingState = false
    }
    
    public func refreshProProofIfNeeded(
        accessExpiryTimestampMs: UInt64,
        autoRenewing: Bool,
        status: Network.SessionPro.BackendUserProStatus
    ) async throws {
        guard status == .active else { return }
        
        let needsNewProof: Bool = await {
            guard let currentProof: Network.SessionPro.ProProof = await proProofStream.getCurrent() else {
                return true
            }
            
            let sixtyMinutesBeforeAccessExpiry: UInt64 = (accessExpiryTimestampMs - (60 * 60))
            let sixtyMinutesBeforeProofExpiry: UInt64 = (currentProof.expiryUnixTimestampMs - (60 * 60))
            let now: UInt64 = dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
            
            return (
                sixtyMinutesBeforeProofExpiry < now &&
                now < sixtyMinutesBeforeAccessExpiry &&
                autoRenewing
            )
        }()
        
        /// Only generate a new proof if we need one
        guard needsNewProof else { return }
        
        let rotatingKeyPair: KeyPair = try (
            self.rotatingKeyPair ??
            dependencies[singleton: .crypto].tryGenerate(.ed25519KeyPair())
        )
        
        let request = try Network.SessionPro.generateProProof(
            masterKeyPair: try dependencies[singleton: .crypto].tryGenerate(.sessionProMasterKeyPair()),
            rotatingKeyPair: rotatingKeyPair,
            using: dependencies
        )
        // FIXME: Make this async/await when the refactored networking is merged
        let response: Network.SessionPro.AddProPaymentOrGenerateProProofResponse = try await request
            .send(using: dependencies)
            .values
            .first(where: { _ in true })?.1 ?? { throw NetworkError.invalidResponse }()
        
        guard response.header.errors.isEmpty else {
            let errorString: String = response.header.errors.joined(separator: ", ")
            Log.error(.sessionPro, "Failed to generate new pro proof due to error(s): \(errorString)")
            throw NetworkError.explicit(errorString)
        }
        
        /// Update the config
        try await dependencies[singleton: .storage].writeAsync { [dependencies] db in
            try dependencies.mutate(cache: .libSession) { cache in
                try cache.performAndPushChange(db, for: .userProfile) { _ in
                    cache.updateProConfig(
                        proConfig: SessionPro.ProConfig(
                            rotatingPrivateKey: rotatingKeyPair.secretKey,
                            proProof: response.proof
                        )
                    )
                }
            }
        }
        
        /// Send the proof and status events on the streams
        ///
        /// **Note:** We can assume that the users status is `active` since they just successfully generated a pro proof
        let proofIsActive: Bool = proProofIsActive(
            for: response.proof,
            atTimestampMs: dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
        )
        let proStatus: Network.SessionPro.BackendUserProStatus = (proofIsActive ? .active : .expired)
        syncState.update(
            rotatingKeyPair: .set(to: rotatingKeyPair),
            backendUserProStatus: .set(to: proStatus),
            proProof: .set(to: response.proof)
        )
        self.rotatingKeyPair = rotatingKeyPair
        await self.proProofStream.send(response.proof)
        await self.backendUserProStatusStream.send(proStatus)
    }
    
    public func addProPayment(transactionId: String) async throws {
        /// First we need to add the pro payment to the Pro backend
        let rotatingKeyPair: KeyPair = try (
            self.rotatingKeyPair ??
            dependencies[singleton: .crypto].tryGenerate(.ed25519KeyPair())
        )
        let request = try Network.SessionPro.addProPayment(
            transactionId: transactionId,
            masterKeyPair: try dependencies[singleton: .crypto].tryGenerate(.sessionProMasterKeyPair()),
            rotatingKeyPair: rotatingKeyPair,
            using: dependencies
        )
        // FIXME: Make this async/await when the refactored networking is merged
        let response: Network.SessionPro.AddProPaymentOrGenerateProProofResponse = try await request
            .send(using: dependencies)
            .values
            .first(where: { _ in true })?.1 ?? { throw NetworkError.invalidResponse }()
        
        guard response.header.errors.isEmpty else {
            let errorString: String = response.header.errors.joined(separator: ", ")
            Log.error(.sessionPro, "Transaction submission failed due to error(s): \(errorString)")
            throw NetworkError.explicit(errorString)
        }
        
        /// Update the config
        try await dependencies[singleton: .storage].writeAsync { [dependencies] db in
            try dependencies.mutate(cache: .libSession) { cache in
                try cache.performAndPushChange(db, for: .userProfile) { _ in
                    cache.updateProConfig(
                        proConfig: SessionPro.ProConfig(
                            rotatingPrivateKey: rotatingKeyPair.secretKey,
                            proProof: response.proof
                        )
                    )
                }
            }
        }
        
        /// Send the proof and status events on the streams
        ///
        /// **Note:** We can assume that the users status is `active` since they just successfully added a pro payment and
        /// received a pro proof
        let proofIsActive: Bool = proProofIsActive(
            for: response.proof,
            atTimestampMs: dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
        )
        let proStatus: Network.SessionPro.BackendUserProStatus = (proofIsActive ? .active : .expired)
        syncState.update(
            rotatingKeyPair: .set(to: rotatingKeyPair),
            backendUserProStatus: .set(to: proStatus),
            proProof: .set(to: response.proof)
        )
        self.rotatingKeyPair = rotatingKeyPair
        await self.proProofStream.send(response.proof)
        await self.backendUserProStatusStream.send(proStatus)
        
        /// Just in case we refresh the pro state (this will avoid needless requests based on the current state but will resolve other
        /// edge-cases since it's the main driver to the Pro state)
        try? await refreshProState()
    }
        
    // MARK: - Internal Functions
    
    private func clearProProof() async throws {
        try await dependencies[singleton: .storage].writeAsync { [dependencies] db in
            try dependencies.mutate(cache: .libSession) { cache in
                try cache.performAndPushChange(db, for: .userProfile) { _ in
                    cache.removeProConfig()
                }
            }
        }
    }
    
    private func updateExpiryCTAs(
        accessExpiryTimestampMs: UInt64,
        autoRenewing: Bool,
        status: Network.SessionPro.BackendUserProStatus
    ) async {
        let now: UInt64 = dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
        let sevenDaysBeforeExpiry: UInt64 = (accessExpiryTimestampMs - (7 * 60 * 60))
        let thirtyDaysAfterExpiry: UInt64 = (accessExpiryTimestampMs + (30 * 60 * 60))
        
        // TODO: [PRO] Need to add these in (likely part of pro settings)
    }
    
    private func startProStatusObservations() {
        proStatusObservationTask?.cancel()
        proStatusObservationTask = Task {
            await withTaskGroup(of: Void.self) { [weak self, dependencies] group in
                if #available(iOS 16, *) {
                    /// Observe the main Session Pro feature flag
                    group.addTask {
                        for await proEnabled in dependencies.stream(feature: .sessionProEnabled) {
                            guard proEnabled else {
                                self?.syncState.update(backendUserProStatus: .set(to: nil))
                                await self?.backendUserProStatusStream.send(.none)
                                continue
                            }
                            
                            /// Restart the observation (will fetch the correct current states)
                            try? await self?.refreshProState()
                        }
                    }
                    
                    /// Observe the explicit mocking for the current session pro status
                    group.addTask {
                        for await status in dependencies.stream(feature: .mockCurrentUserSessionProBackendStatus) {
                            /// Ignore status updates if pro is enabled, and if the mock status was removed we need to fetch
                            /// the "real" status
                            guard dependencies[feature: .sessionProEnabled] else { continue }
                            guard let status: Network.SessionPro.BackendUserProStatus = status else {
                                try? await self?.refreshProState()
                                continue
                            }
                            
                            self?.syncState.update(backendUserProStatus: .set(to: status))
                            await self?.backendUserProStatusStream.send(status)
                        }
                    }
                }
                
                /// If Session Pro isn't enabled then no need to do any of the other tasks (they check the proper Session Pro stauts
                /// via `libSession` and the network
                guard dependencies[feature: .sessionProEnabled] else {
                    await group.waitForAll()
                    return
                }
                
                await group.waitForAll()
            }
        }
    }
}

// MARK: - SyncState

private final class SessionProManagerSyncState {
    private let lock: NSLock = NSLock()
    private let _dependencies: Dependencies
    private var _rotatingKeyPair: KeyPair? = nil
    private var _backendUserProStatus: Network.SessionPro.BackendUserProStatus? = nil
    private var _proProof: Network.SessionPro.ProProof? = nil
    private var _proFeatures: SessionPro.Features = .none
    
    fileprivate var dependencies: Dependencies { lock.withLock { _dependencies } }
    fileprivate var rotatingKeyPair: KeyPair? { lock.withLock { _rotatingKeyPair } }
    fileprivate var backendUserProStatus: Network.SessionPro.BackendUserProStatus? {
        lock.withLock { _backendUserProStatus }
    }
    fileprivate var proProof: Network.SessionPro.ProProof? { lock.withLock { _proProof } }
    fileprivate var proFeatures: SessionPro.Features? { lock.withLock { _proFeatures } }
    
    fileprivate init(using dependencies: Dependencies) {
        self._dependencies = dependencies
    }
    
    fileprivate func update(
        rotatingKeyPair: Update<KeyPair?> = .useExisting,
        backendUserProStatus: Update<Network.SessionPro.BackendUserProStatus?> = .useExisting,
        proProof: Update<Network.SessionPro.ProProof?> = .useExisting,
        proFeatures: Update<SessionPro.Features> = .useExisting
    ) {
        lock.withLock {
            self._rotatingKeyPair = rotatingKeyPair.or(self._rotatingKeyPair)
            self._backendUserProStatus = backendUserProStatus.or(self._backendUserProStatus)
            self._proProof = proProof.or(self._proProof)
            self._proFeatures = proFeatures.or(self._proFeatures)
        }
    }
}

// MARK: - SessionProManagerType

public protocol SessionProManagerType: SessionProUIManagerType {
    var rotatingKeyPair: KeyPair? { get }
    
    nonisolated var characterLimit: Int { get }
    nonisolated var currentUserCurrentRotatingKeyPair: KeyPair? { get }
    nonisolated var currentUserCurrentBackendProStatus: Network.SessionPro.BackendUserProStatus? { get }
    nonisolated var currentUserCurrentProProof: Network.SessionPro.ProProof? { get }
    
    nonisolated var backendUserProStatus: AsyncStream<Network.SessionPro.BackendUserProStatus?> { get }
    nonisolated var proProof: AsyncStream<Network.SessionPro.ProProof?> { get }
    
    nonisolated func proStatus<I: DataProtocol>(
        for proof: Network.SessionPro.ProProof?,
        verifyPubkey: I?,
        atTimestampMs timestampMs: UInt64
    ) -> SessionPro.ProStatus
    nonisolated func proProofIsActive(
        for proof: Network.SessionPro.ProProof?,
        atTimestampMs timestampMs: UInt64
    ) -> Bool
    nonisolated func features(for message: String, features: SessionPro.Features) -> SessionPro.FeaturesForMessage
    nonisolated func attachProInfoIfNeeded(message: Message) -> Message
    func updateWithLatestFromUserConfig() async
    
    func refreshProState() async throws
    func addProPayment(transactionId: String) async throws
}

public extension SessionProManagerType {
    nonisolated func features(for message: String) -> SessionPro.FeaturesForMessage {
        return features(for: message, features: .none)
    }
}
