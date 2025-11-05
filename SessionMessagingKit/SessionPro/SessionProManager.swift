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
    private var proStatusObservationTask: Task<Void, Never>?
    private var masterKeyPair: KeyPair?
    public var rotatingKeyPair: KeyPair?
    
    nonisolated private let backendUserProStatusStream: CurrentValueAsyncStream<Network.SessionPro.BackendUserProStatus?> = CurrentValueAsyncStream(nil)
    nonisolated private let proProofStream: CurrentValueAsyncStream<Network.SessionPro.ProProof?> = CurrentValueAsyncStream(nil)
    nonisolated private let decodedProForMessageStream: CurrentValueAsyncStream<SessionPro.DecodedProForMessage?> = CurrentValueAsyncStream(nil)
    
    nonisolated public var currentUserCurrentRotatingKeyPair: KeyPair? { syncState.rotatingKeyPair }
    nonisolated public var currentUserIsCurrentlyPro: Bool { syncState.backendUserProStatus == .active }
    nonisolated public var currentUserCurrentProProof: Network.SessionPro.ProProof? { syncState.proProof }
    nonisolated public var currentUserCurrentDecodedProForMessage: SessionPro.DecodedProForMessage? {
        syncState.decodedProForMessage
    }
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
    nonisolated public var decodedProForMessage: AsyncStream<SessionPro.DecodedProForMessage?> {
        decodedProForMessageStream.stream
    }
    
    // MARK: - Initialization
    
    public init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.syncState = SessionProManagerSyncState(using: dependencies)
        self.masterKeyPair = dependencies[singleton: .crypto].generate(.sessionProMasterKeyPair())
        
        Task {
            await updateWithLatestFromUserConfig()
            await startProStatusObservations()
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
    
    nonisolated public func features(for message: String, extraFeatures: SessionPro.ExtraFeatures) -> SessionPro.FeaturesForMessage {
        guard let cMessage: [CChar] = message.cString(using: .utf8) else {
            return SessionPro.FeaturesForMessage.invalidString
        }
        
        return SessionPro.FeaturesForMessage(
            session_protocol_pro_features_for_utf8(
                cMessage,
                (cMessage.count - 1),  /// Need to `- 1` to avoid counting the null-termination character
                extraFeatures.libSessionValue
            )
        )
    }
    
    public func updateWithLatestFromUserConfig() async {
        let proConfig: SessionPro.ProConfig? = dependencies.mutate(cache: .libSession) { $0.proConfig }
        
        let rotatingKeyPair: KeyPair? = try? proConfig.map { config in
            guard config.rotatingPrivateKey.count >= 32 else { return nil }
            
            return try dependencies[singleton: .crypto].tryGenerate(
                .ed25519KeyPair(seed: config.rotatingPrivateKey.prefix(upTo: 32))
            )
        }
        
        /// Update the `syncState` first (just in case an update triggered from the async state results in something accessing the
        /// sync state)
        syncState.update(
            rotatingKeyPair: .set(to: rotatingKeyPair),
            proProof: .set(to: proConfig?.proProof)
        )
        
        /// Then update the async state and streams
        self.rotatingKeyPair = rotatingKeyPair
        await self.proProofStream.send(proConfig?.proProof)
    }
    
    public func upgradeToPro(completion: ((_ result: Bool) -> Void)?) async {
        dependencies.set(feature: .mockCurrentUserSessionProBackendStatus, to: .active)
        await backendUserProStatusStream.send(.active)
        completion?(true)
    }
    
    @discardableResult @MainActor public func showSessionProCTAIfNeeded(
        _ variant: ProCTAModal.Variant,
        dismissType: Modal.DismissType,
        beforePresented: (() -> Void)?,
        afterClosed: (() -> Void)?,
        presenting: ((UIViewController) -> Void)?
    ) -> Bool {
        guard
            syncState.dependencies[feature: .sessionProEnabled],
            syncState.backendUserProStatus != .active
        else { return false }
        
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
        
    // MARK: - Internal Functions
    
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
                            
                        }
                    }
                    
                    /// Observe the explicit mocking for the current session pro status
                    group.addTask {
                        for await status in dependencies.stream(feature: .mockCurrentUserSessionProBackendStatus) {
                            /// Ignore status updates if pro is enabled, and if the mock status was removed we need to fetch
                            /// the "real" status
                            guard dependencies[feature: .sessionProEnabled] else { continue }
                            guard let status: Network.SessionPro.BackendUserProStatus = status else {
                                self?.syncState.update(backendUserProStatus: .set(to: nil))
                                await self?.backendUserProStatusStream.send(nil)
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
    private var _decodedProForMessage: SessionPro.DecodedProForMessage? = nil
    
    fileprivate var dependencies: Dependencies { lock.withLock { _dependencies } }
    fileprivate var rotatingKeyPair: KeyPair? { lock.withLock { _rotatingKeyPair } }
    fileprivate var backendUserProStatus: Network.SessionPro.BackendUserProStatus? {
        lock.withLock { _backendUserProStatus }
    }
    fileprivate var proProof: Network.SessionPro.ProProof? { lock.withLock { _proProof } }
    fileprivate var decodedProForMessage: SessionPro.DecodedProForMessage? { lock.withLock { _decodedProForMessage } }
    
    fileprivate init(using dependencies: Dependencies) {
        self._dependencies = dependencies
    }
    
    fileprivate func update(
        rotatingKeyPair: Update<KeyPair?> = .useExisting,
        backendUserProStatus: Update<Network.SessionPro.BackendUserProStatus?> = .useExisting,
        proProof: Update<Network.SessionPro.ProProof?> = .useExisting,
        decodedProForMessage: Update<SessionPro.DecodedProForMessage?> = .useExisting
    ) {
        lock.withLock {
            self._rotatingKeyPair = rotatingKeyPair.or(self._rotatingKeyPair)
            self._backendUserProStatus = backendUserProStatus.or(self._backendUserProStatus)
            self._proProof = proProof.or(self._proProof)
            self._decodedProForMessage = decodedProForMessage.or(self._decodedProForMessage)
        }
    }
}

// MARK: - SessionProManagerType

public protocol SessionProManagerType: SessionProUIManagerType {
    var rotatingKeyPair: KeyPair? { get }
    
    nonisolated var characterLimit: Int { get }
    nonisolated var currentUserCurrentRotatingKeyPair: KeyPair? { get }
    nonisolated var currentUserCurrentProProof: Network.SessionPro.ProProof? { get }
    nonisolated var currentUserCurrentDecodedProForMessage: SessionPro.DecodedProForMessage? { get }
    
    nonisolated var backendUserProStatus: AsyncStream<Network.SessionPro.BackendUserProStatus?> { get }
    nonisolated var proProof: AsyncStream<Network.SessionPro.ProProof?> { get }
    
    nonisolated func proStatus<I: DataProtocol>(
        for proof: Network.SessionPro.ProProof?,
        verifyPubkey: I?,
        atTimestampMs timestampMs: UInt64
    ) -> SessionPro.ProStatus
    nonisolated func features(for message: String, extraFeatures: SessionPro.ExtraFeatures) -> SessionPro.FeaturesForMessage
    func updateWithLatestFromUserConfig() async
}

public extension SessionProManagerType {
    nonisolated func features(for message: String) -> SessionPro.FeaturesForMessage {
        return features(for: message, extraFeatures: .none)
    }
}
