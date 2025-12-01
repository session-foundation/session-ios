// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import StoreKit
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
    private var proMockingObservationTask: Task<Void, Never>?
    private var rotatingKeyPair: KeyPair?
    public var plans: [SessionPro.Plan] = []
    
    nonisolated private let buildVariantStream: CurrentValueAsyncStream<BuildVariant> = CurrentValueAsyncStream(BuildVariant.current)
    nonisolated private let loadingStateStream: CurrentValueAsyncStream<SessionPro.LoadingState> = CurrentValueAsyncStream(.loading)
    nonisolated private let proStatusStream: CurrentValueAsyncStream<Network.SessionPro.BackendUserProStatus?> = CurrentValueAsyncStream(nil)
    nonisolated private let autoRenewingStream: CurrentValueAsyncStream<Bool?> = CurrentValueAsyncStream(nil)
    nonisolated private let accessExpiryTimestampMsStream: CurrentValueAsyncStream<UInt64?> = CurrentValueAsyncStream(nil)
    nonisolated private let latestPaymentItemStream: CurrentValueAsyncStream<Network.SessionPro.PaymentItem?> = CurrentValueAsyncStream(nil)
    nonisolated private let latestPaymentOriginatingPlatformStream: CurrentValueAsyncStream<SessionProUI.ClientPlatform> = CurrentValueAsyncStream(.iOS)
    nonisolated private let originatingAccountStream: CurrentValueAsyncStream<SessionPro.OriginatingAccount> = CurrentValueAsyncStream(.originatingAccount)
    nonisolated private let refundingStatusStream: CurrentValueAsyncStream<SessionPro.RefundingStatus> = CurrentValueAsyncStream(.notRefunding)
    
    nonisolated public var currentUserCurrentRotatingKeyPair: KeyPair? { syncState.rotatingKeyPair }
    nonisolated public var currentUserCurrentProStatus: Network.SessionPro.BackendUserProStatus? {
        syncState.proStatus
    }
    nonisolated public var currentUserCurrentProProof: Network.SessionPro.ProProof? { syncState.proProof }
    nonisolated public var currentUserCurrentProProfileFeatures: SessionPro.ProfileFeatures? { syncState.proProfileFeatures }
    nonisolated public var currentUserIsCurrentlyPro: Bool { syncState.proStatus == .active }
    
    nonisolated public var pinnedConversationLimit: Int { SessionPro.PinnedConversationLimit }
    nonisolated public var characterLimit: Int {
        (currentUserIsCurrentlyPro ? SessionPro.ProCharacterLimit : SessionPro.CharacterLimit)
    }
    nonisolated public var currentUserIsPro: AsyncStream<Bool> {
        proStatusStream.stream
            .map { $0 == .active }
            .asAsyncStream()
    }
    
    nonisolated public var buildVariant: AsyncStream<BuildVariant> { buildVariantStream.stream }
    nonisolated public var loadingState: AsyncStream<SessionPro.LoadingState> { loadingStateStream.stream }
    nonisolated public var proStatus: AsyncStream<Network.SessionPro.BackendUserProStatus?> { proStatusStream.stream }
    nonisolated public var autoRenewing: AsyncStream<Bool?> { autoRenewingStream.stream }
    nonisolated public var accessExpiryTimestampMs: AsyncStream<UInt64?> { accessExpiryTimestampMsStream.stream }
    nonisolated public var latestPaymentItem: AsyncStream<Network.SessionPro.PaymentItem?> { latestPaymentItemStream.stream }
    nonisolated public var latestPaymentOriginatingPlatform: AsyncStream<SessionProUI.ClientPlatform> {
        latestPaymentOriginatingPlatformStream.stream
    }
    nonisolated public var originatingAccount: AsyncStream<SessionPro.OriginatingAccount> { originatingAccountStream.stream }
    nonisolated public var refundingStatus: AsyncStream<SessionPro.RefundingStatus> { refundingStatusStream.stream }
    
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
        proMockingObservationTask?.cancel()
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
    ) -> SessionPro.DecodedStatus? {
        guard let proof: Network.SessionPro.ProProof else { return nil }
        
        var cProProof: session_protocol_pro_proof = proof.libSessionValue
        let cVerifyPubkey: [UInt8] = (verifyPubkey.map { Array($0) } ?? [])
        
        return SessionPro.DecodedStatus(
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
    
    nonisolated public func features(for message: String) -> SessionPro.FeaturesForMessage {
        guard let cMessage: [CChar] = message.cString(using: .utf8) else {
            return SessionPro.FeaturesForMessage.invalidString
        }
        
        return SessionPro.FeaturesForMessage(
            session_protocol_pro_features_for_utf8(
                cMessage,
                (cMessage.count - 1)  /// Need to `- 1` to avoid counting the null-termination character
            )
        )
    }
    
    nonisolated public func attachProInfoIfNeeded(message: Message) -> Message {
        let featuresForMessage: SessionPro.FeaturesForMessage = features(
            for: ((message as? VisibleMessage)?.text ?? "")
        )
        let profileFeatures: SessionPro.ProfileFeatures = (syncState.proProfileFeatures ?? .none)
        
        /// We only want to attach the `proFeatures` and `proProof` if a pro feature is _actually_ used
        guard
            featuresForMessage.status == .success, (
                profileFeatures != .none ||
                featuresForMessage.features != .none
            ),
            let proof: Network.SessionPro.ProProof = syncState.proProof
        else {
            if featuresForMessage.status != .success {
                Log.error(.sessionPro, "Failed to get features for outgoing message due to error: \(featuresForMessage.error ?? "Unknown error")")
            }
            return message
        }
        
        let updatedMessage: Message = message
        updatedMessage.proMessageFeatures = featuresForMessage.features
        updatedMessage.proProfileFeatures = profileFeatures
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
        typealias ProState = (
            proConfig: SessionPro.ProConfig?,
            profile: Profile,
            accessExpiryTimestampMs: UInt64
        )
        let proState: ProState = dependencies.mutate(cache: .libSession) {
            ($0.proConfig, $0.profile, $0.proAccessExpiryTimestampMs)
        }
        
        let rotatingKeyPair: KeyPair? = try? proState.proConfig.map { config in
            guard config.rotatingPrivateKey.count >= 32 else { return nil }
            
            return try dependencies[singleton: .crypto].tryGenerate(
                .ed25519KeyPair(seed: config.rotatingPrivateKey.prefix(upTo: 32))
            )
        }
        
        /// Update the `syncState` first (just in case an update triggered from the async state results in something accessing the
        /// sync state)
        let proStatus: Network.SessionPro.BackendUserProStatus = {
            guard let proof: Network.SessionPro.ProProof = proState.proConfig?.proProof else {
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
            proStatus: .set(to: mockedIfNeeded(proStatus)),
            proProof: .set(to: proState.proConfig?.proProof),
            proProfileFeatures: .set(to: proState.profile.proFeatures)
        )
        
        /// Then update the async state and streams
        let oldAccessExpiryTimestampMs: UInt64? = await self.accessExpiryTimestampMsStream.getCurrent()
        self.rotatingKeyPair = rotatingKeyPair
        await self.proStatusStream.send(mockedIfNeeded(proStatus))
        await self.accessExpiryTimestampMsStream.send(proState.accessExpiryTimestampMs)
        await self.sendUpdatedRefundingStatusState()
        
        /// If the `accessExpiryTimestampMs` value changed then we should trigger a refresh because it generally means that
        /// other device did something that should refresh the pro state
        if proState.accessExpiryTimestampMs != oldAccessExpiryTimestampMs {
            try? await refreshProState()
        }
    }
    
    @discardableResult @MainActor public func showSessionProCTAIfNeeded(
        _ variant: ProCTAModal.Variant,
        dismissType: Modal.DismissType,
        onConfirm: (() -> Void)?,
        onCancel: (() -> Void)?,
        afterClosed: (() -> Void)?,
        presenting: ((UIViewController) -> Void)?
    ) -> Bool {
        guard syncState.dependencies[feature: .sessionProEnabled] else { return false }
        
        switch variant {
            case .groupLimit: break /// The `groupLimit` CTA can be shown for Session Pro users as well
            default:
                guard syncState.proStatus != .active else { return false }
                
                break
        }
        
        let sessionProModal: ModalHostingViewController = ModalHostingViewController(
            modal: ProCTAModal(
                variant: variant,
                dataManager: syncState.dependencies[singleton: .imageDataManager],
                sessionProUIManager: self,
                dismissType: dismissType,
                onConfirm: onConfirm,
                onCancel: onCancel,
                afterClosed: afterClosed
            )
        )
        presenting?(sessionProModal)
        
        return true
    }
    
    public func upgradeToPro(completion: ((_ result: Bool) -> Void)?) async {
        // TODO: [PRO] Need to actually implement this
        dependencies.set(feature: .mockCurrentUserSessionProBackendStatus, to: .simulate(.active))
        await proStatusStream.send(.active)
        await sendUpdatedRefundingStatusState()
        completion?(true)
    }
    
    // MARK: - Pro State Management
    
    public func refreshProState() async throws {
        /// No point refreshing the state if there is a refresh in progress
        guard !isRefreshingState else { return }
        
        isRefreshingState = true
        defer { isRefreshingState = false }
        
        /// Only reset the `loadingState` if it's currently in an error state
        if await loadingStateStream.getCurrent() == .error {
            await loadingStateStream.send(mockedIfNeeded(.loading))
        }
        
        /// Get the product list from the AppStore first (need this to populate the UI)
        if plans.isEmpty {
            plans = try await SessionPro.Plan.retrievePlans()
        }
        
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
            await loadingStateStream.send(mockedIfNeeded(.error))
            throw NetworkError.explicit(errorString)
        }
        
        syncState.update(proStatus: .set(to: mockedIfNeeded(response.status)))
        await self.proStatusStream.send(mockedIfNeeded(response.status))
        await self.autoRenewingStream.send(response.autoRenewing)
        await self.accessExpiryTimestampMsStream.send(response.expiryTimestampMs)
        await self.latestPaymentItemStream.send(response.items.first)
        await self.latestPaymentOriginatingPlatformStream.send(mockedIfNeeded(
            SessionProUI.ClientPlatform(response.items.first?.paymentProvider)
        ))
        await self.sendUpdatedRefundingStatusState()
        
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
        
        await loadingStateStream.send(mockedIfNeeded(.success))
    }
    
    public func refreshProProofIfNeeded(
        accessExpiryTimestampMs: UInt64,
        autoRenewing: Bool,
        status: Network.SessionPro.BackendUserProStatus
    ) async throws {
        guard status == .active else { return }
        
        let needsNewProof: Bool = {
            guard let currentProof: Network.SessionPro.ProProof = syncState.proProof else {
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
            proStatus: .set(to: mockedIfNeeded(proStatus)),
            proProof: .set(to: response.proof)
        )
        self.rotatingKeyPair = rotatingKeyPair
        await self.proStatusStream.send(mockedIfNeeded(proStatus))
        await self.sendUpdatedRefundingStatusState()
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
            proStatus: .set(to: mockedIfNeeded(proStatus)),
            proProof: .set(to: response.proof)
        )
        self.rotatingKeyPair = rotatingKeyPair
        await self.proStatusStream.send(mockedIfNeeded(proStatus))
        await self.sendUpdatedRefundingStatusState()
        
        /// Just in case we refresh the pro state (this will avoid needless requests based on the current state but will resolve other
        /// edge-cases since it's the main driver to the Pro state)
        try? await refreshProState()
    }
    
    public func requestRefund(
        scene: UIWindowScene
    ) async throws {
        guard let latestPaymentItem: Network.SessionPro.PaymentItem = await latestPaymentItemStream.getCurrent() else {
            throw NetworkError.explicit("No latest payment item")
        }
        
        /// User has already requested a refund for this item
        guard latestPaymentItem.refundRequestedTimestampMs == 0 else {
            throw NetworkError.explicit("Refund already requested for latest payment")
        }
        
        /// Only Apple support refunding via this mechanism so no point continuing if we don't have a `appleTransactionId`
        guard let transactionId: String = latestPaymentItem.appleTransactionId else {
            throw NetworkError.explicit("Latest payment wasn't originated from an Apple device")
        }
        
        /// If we don't have the `fakeAppleSubscriptionForDev` feature enabled then we need to actually request the refund from Apple
        if !dependencies[feature: .fakeAppleSubscriptionForDev] {
            var transactions: [Transaction] = []
            
            for await result in Transaction.currentEntitlements {
                if case .verified(let transaction) = result {
                    transactions.append(transaction)
                }
            }
            
            let sortedTransactions: [Transaction] = transactions.sorted { $0.purchaseDate > $1.purchaseDate }
            let latestTransaction: Transaction? = sortedTransactions.first
            let latestPaymentItemTransaction: Transaction? = sortedTransactions.first(where: { "\($0.id)" == latestPaymentItem.appleTransactionId })
            
            if latestTransaction != latestPaymentItemTransaction {
                Log.warn(.sessionPro, "The latest transaction didn't match the latest payment item")
            }
            
            /// Prioritise the transaction that matches the latest payment item
            guard let targetTransaction: Transaction = (latestPaymentItemTransaction ?? latestTransaction) else {
                throw NetworkError.explicit("No Transaction")
            }
            
            let status: Transaction.RefundRequestStatus = try await targetTransaction.beginRefundRequest(in: scene)
            
            switch status {
                case .success: break    /// Continue on to send the refund to our backend
                case .userCancelled: throw NetworkError.explicit("Cancelled refund request")
                @unknown default: throw NetworkError.explicit("Unknown refund request status")
            }
        }
        
        let refundRequestedTimestampMs: UInt64 = dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
        let request = try Network.SessionPro.setPaymentRefundRequested(
            transactionId: transactionId,
            refundRequestedTimestampMs: refundRequestedTimestampMs,
            masterKeyPair: try dependencies[singleton: .crypto].tryGenerate(.sessionProMasterKeyPair()),
            using: dependencies
        )
        
        // FIXME: Make this async/await when the refactored networking is merged
        let response: Network.SessionPro.SetPaymentRefundRequestedResponse = try await request
            .send(using: dependencies)
            .values
            .first(where: { _ in true })?.1 ?? { throw NetworkError.invalidResponse }()
        
        guard response.header.errors.isEmpty else {
            let errorString: String = response.header.errors.joined(separator: ", ")
            Log.error(.sessionPro, "Refund submission failed due to error(s): \(errorString)")
            throw NetworkError.explicit(errorString)
        }
        
        /// Need to refresh the pro state to get the updated payment item (which should now include a `refundRequestedTimestampMs`)
        try await refreshProState()
    }
        
    // MARK: - Internal Functions
    
    /// The user is in a refunding state when their pro status is `active` and the `refundRequestedTimestampMs` is not `0`
    private func sendUpdatedRefundingStatusState() async {
        let status: Network.SessionPro.BackendUserProStatus? = await proStatusStream.getCurrent()
        let paymentItem: Network.SessionPro.PaymentItem? = await latestPaymentItemStream.getCurrent()
        
        await refundingStatusStream.send(
            mockedIfNeeded(
                SessionPro.RefundingStatus(
                    status == .active &&
                    (paymentItem?.refundRequestedTimestampMs ?? 0) > 0
                )
            )
        )
    }
    
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
}

// MARK: - SyncState

private final class SessionProManagerSyncState {
    private let lock: NSLock = NSLock()
    private let _dependencies: Dependencies
    private var _rotatingKeyPair: KeyPair? = nil
    private var _proStatus: Network.SessionPro.BackendUserProStatus? = nil
    private var _proProof: Network.SessionPro.ProProof? = nil
    private var _proProfileFeatures: SessionPro.ProfileFeatures = .none
    
    fileprivate var dependencies: Dependencies { lock.withLock { _dependencies } }
    fileprivate var rotatingKeyPair: KeyPair? { lock.withLock { _rotatingKeyPair } }
    fileprivate var proStatus: Network.SessionPro.BackendUserProStatus? { lock.withLock { _proStatus } }
    fileprivate var proProof: Network.SessionPro.ProProof? { lock.withLock { _proProof } }
    fileprivate var proProfileFeatures: SessionPro.ProfileFeatures? { lock.withLock { _proProfileFeatures } }
    
    fileprivate init(using dependencies: Dependencies) {
        self._dependencies = dependencies
    }
    
    fileprivate func update(
        rotatingKeyPair: Update<KeyPair?> = .useExisting,
        proStatus: Update<Network.SessionPro.BackendUserProStatus?> = .useExisting,
        proProof: Update<Network.SessionPro.ProProof?> = .useExisting,
        proProfileFeatures: Update<SessionPro.ProfileFeatures> = .useExisting
    ) {
        lock.withLock {
            self._rotatingKeyPair = rotatingKeyPair.or(self._rotatingKeyPair)
            self._proStatus = proStatus.or(self._proStatus)
            self._proProof = proProof.or(self._proProof)
            self._proProfileFeatures = proProfileFeatures.or(self._proProfileFeatures)
        }
    }
}

// MARK: - SessionProManagerType

public protocol SessionProManagerType: SessionProUIManagerType {
    var plans: [SessionPro.Plan] { get }
    
    nonisolated var characterLimit: Int { get }
    nonisolated var currentUserCurrentRotatingKeyPair: KeyPair? { get }
    nonisolated var currentUserCurrentProStatus: Network.SessionPro.BackendUserProStatus? { get }
    nonisolated var currentUserCurrentProProof: Network.SessionPro.ProProof? { get }
    nonisolated var currentUserCurrentProProfileFeatures: SessionPro.ProfileFeatures? { get }
    // TODO: [PRO] Need to finish off the "buildVariant" logic
    nonisolated var buildVariant: AsyncStream<BuildVariant> { get }
    nonisolated var loadingState: AsyncStream<SessionPro.LoadingState> { get }
    nonisolated var proStatus: AsyncStream<Network.SessionPro.BackendUserProStatus?> { get }
    nonisolated var autoRenewing: AsyncStream<Bool?> { get }
    nonisolated var accessExpiryTimestampMs: AsyncStream<UInt64?> { get }
    nonisolated var latestPaymentItem: AsyncStream<Network.SessionPro.PaymentItem?> { get }
    nonisolated var latestPaymentOriginatingPlatform: AsyncStream<SessionProUI.ClientPlatform> { get }
    nonisolated var originatingAccount: AsyncStream<SessionPro.OriginatingAccount> { get }
    nonisolated var refundingStatus: AsyncStream<SessionPro.RefundingStatus> { get }
    
    nonisolated func proStatus<I: DataProtocol>(
        for proof: Network.SessionPro.ProProof?,
        verifyPubkey: I?,
        atTimestampMs timestampMs: UInt64
    ) -> SessionPro.DecodedStatus?
    nonisolated func proProofIsActive(
        for proof: Network.SessionPro.ProProof?,
        atTimestampMs timestampMs: UInt64
    ) -> Bool
    nonisolated func features(for message: String) -> SessionPro.FeaturesForMessage
    nonisolated func attachProInfoIfNeeded(message: Message) -> Message
    func updateWithLatestFromUserConfig() async
    
    func refreshProState() async throws
    func addProPayment(transactionId: String) async throws
    func requestRefund(scene: UIWindowScene) async throws
}

// MARK: - Convenience

extension SessionProUI.ClientPlatform {
    /// The originating platform the latest payment came from
    ///
    /// **Note:** There may not be a latest payment, in which case we default to `iOS` because we are on an `iOS` device
    init(_ provider: Network.SessionPro.PaymentProvider?) {
        switch provider {
            case .none: self = .iOS
            case .appStore: self = .iOS
            case .playStore: self = .android
        }
    }
}

// MARK: - Observations

// stringlint:ignore_contents
public extension ObservableKey {
    static func buildVariant(_ manager: SessionProManagerType) -> ObservableKey {
        return ObservableKey.stream(
            key: "buildVariant",
            generic: .buildVariant
        ) { [weak manager] in manager?.buildVariant }
    }
    
    static func currentUserProLoadingState(_ manager: SessionProManagerType) -> ObservableKey {
        return ObservableKey.stream(
            key: "currentUserProLoadingState",
            generic: .currentUserProLoadingState
        ) { [weak manager] in manager?.loadingState }
    }
    
    static func currentUserProStatus(_ manager: SessionProManagerType) -> ObservableKey {
        return ObservableKey.stream(
            key: "currentUserProStatus",
            generic: .currentUserProStatus
        ) { [weak manager] in manager?.proStatus }
    }
    
    static func currentUserProAutoRenewing(_ manager: SessionProManagerType) -> ObservableKey {
        return ObservableKey.stream(
            key: "currentUserProAutoRenewing",
            generic: .currentUserProAutoRenewing
        ) { [weak manager] in manager?.autoRenewing }
    }
    
    static func currentUserProAccessExpiryTimestampMs(_ manager: SessionProManagerType) -> ObservableKey {
        return ObservableKey.stream(
            key: "currentUserProAccessExpiryTimestampMs",
            generic: .currentUserProAccessExpiryTimestampMs
        ) { [weak manager] in manager?.accessExpiryTimestampMs }
    }
    
    static func currentUserProLatestPaymentItem(_ manager: SessionProManagerType) -> ObservableKey {
        return ObservableKey.stream(
            key: "currentUserProLatestPaymentItem",
            generic: .currentUserProLatestPaymentItem
        ) { [weak manager] in manager?.latestPaymentItem }
    }
    
    static func currentUserLatestPaymentOriginatingPlatform(_ manager: SessionProManagerType) -> ObservableKey {
        return ObservableKey.stream(
            key: "currentUserLatestPaymentOriginatingPlatform",
            generic: .currentUserLatestPaymentOriginatingPlatform
        ) { [weak manager] in manager?.latestPaymentOriginatingPlatform }
    }
    
    static func currentUserProOriginatingAccount(_ manager: SessionProManagerType) -> ObservableKey {
        return ObservableKey.stream(
            key: "currentUserProOriginatingAccount",
            generic: .currentUserProOriginatingAccount
        ) { [weak manager] in manager?.originatingAccount }
    }
    
    static func currentUserProRefundingStatus(_ manager: SessionProManagerType) -> ObservableKey {
        return ObservableKey.stream(
            key: "currentUserProRefundingStatus",
            generic: .currentUserProRefundingStatus
        ) { [weak manager] in manager?.refundingStatus }
    }
}

// stringlint:ignore_contents
public extension GenericObservableKey {
    static let buildVariant: GenericObservableKey = "buildVariant"
    static let currentUserProLoadingState: GenericObservableKey = "currentUserProLoadingState"
    static let currentUserProStatus: GenericObservableKey = "currentUserProStatus"
    static let currentUserProAutoRenewing: GenericObservableKey = "currentUserProAutoRenewing"
    static let currentUserProAccessExpiryTimestampMs: GenericObservableKey = "currentUserProAccessExpiryTimestampMs"
    static let currentUserProLatestPaymentItem: GenericObservableKey = "currentUserProLatestPaymentItem"
    static let currentUserLatestPaymentOriginatingPlatform: GenericObservableKey = "currentUserLatestPaymentOriginatingPlatform"
    static let currentUserProOriginatingAccount: GenericObservableKey = "currentUserProOriginatingAccount"
    static let currentUserProRefundingStatus: GenericObservableKey = "currentUserProRefundingStatus"
}

// MARK: - Mocking

private extension SessionProManager {
    private func startProStatusObservations() {
        proMockingObservationTask = ObservationBuilder
            .initialValue(MockState(using: dependencies))
            .debounce(for: .milliseconds(10))
            .using(dependencies: dependencies)
            .query { previousValue, _, _, dependencies in
                MockState(previousInfo: previousValue.info, using: dependencies)
            }
            .assign { [weak self] state in
                Task.detached(priority: .userInitiated) {
                    /// If the entire Session Pro feature is disabled then clear any state
                    guard state.info.sessionProEnabled else {
                        self?.syncState.update(
                            rotatingKeyPair: .set(to: nil),
                            proStatus: .set(to: nil),
                            proProof: .set(to: nil),
                            proProfileFeatures: .set(to: .none)
                        )
                        
                        await self?.loadingStateStream.send(.loading)
                        await self?.proStatusStream.send(nil)
                        await self?.autoRenewingStream.send(nil)
                        await self?.accessExpiryTimestampMsStream.send(nil)
                        await self?.latestPaymentItemStream.send(nil)
                        await self?.sendUpdatedRefundingStatusState()
                        return
                    }
                    
                    let needsStateRefresh: Bool = {
                        /// We we just enabled Session Pro then we need to fetch the users state
                        if state.info.sessionProEnabled && state.previousInfo?.sessionProEnabled == false {
                            return true
                        }
                        
                        /// If any of the mock states changed from a mock to use the actual value then we need to know what the
                        /// actual value is (so need to refresh the state)
                        switch (state.previousInfo?.mockProBackendStatus, state.info.mockProBackendStatus) {
                            case (.simulate, .useActual): return true
                            default: break
                        }
                        
                        switch (state.previousInfo?.mockProLoadingState, state.info.mockProLoadingState) {
                            case (.simulate, .useActual): return true
                            default: break
                        }
                        
                        switch (state.previousInfo?.mockOriginatingPlatform, state.info.mockOriginatingPlatform) {
                            case (.simulate, .useActual): return true
                            default: break
                        }
                        
                        switch (state.previousInfo?.mockBuildVariant, state.info.mockBuildVariant) {
                            case (.simulate, .useActual): return true
                            default: break
                        }
                        
                        switch (state.previousInfo?.mockOriginatingAccount, state.info.mockOriginatingAccount) {
                            case (.simulate, .useActual): return true
                            default: break
                        }
                        
                        switch (state.previousInfo?.mockRefundingStatus, state.info.mockRefundingStatus) {
                            case (.simulate, .useActual): return true
                            default: break
                        }
                        
                        if (state.previousInfo?.mockAccessExpiryTimestamp ?? 0) > 0 && state.info.mockAccessExpiryTimestamp == 0 {
                            return true
                        }
                        
                        return false
                    }()
                    
                    /// If we need a state refresh then start a new task to do so (we don't want the mocking to be dependant on the
                    /// result of the refresh so don't wait for it to complete before doing any mock changes)
                    if needsStateRefresh {
                        Task.detached { [weak self] in try await self?.refreshProState() }
                    }
                    
                    /// While it would be easier to just rely on `refreshProState` to update the mocked statuses, that would
                    /// mean the mocking requires network connectivity which isn't ideal, so we also explicitly send out any mock
                    /// changes separately
                    if state.info.mockProBackendStatus != state.previousInfo?.mockProBackendStatus {
                        switch state.info.mockProBackendStatus {
                            case .useActual: break
                            case .simulate(let value):
                                self?.syncState.update(proStatus: .set(to: value))
                                await self?.proStatusStream.send(value)
                                await self?.sendUpdatedRefundingStatusState()
                        }
                    }
                    
                    if state.info.mockProLoadingState != state.previousInfo?.mockProLoadingState {
                        switch state.info.mockProLoadingState {
                            case .useActual: break
                            case .simulate(let value): await self?.loadingStateStream.send(value)
                        }
                    }
                    
                    if state.info.mockOriginatingPlatform != state.previousInfo?.mockOriginatingPlatform {
                        switch state.info.mockOriginatingPlatform {
                            case .useActual: break
                            case .simulate(let value): await self?.latestPaymentOriginatingPlatformStream.send(value)
                        }
                    }
                    
                    if state.info.mockBuildVariant != state.previousInfo?.mockBuildVariant {
                        switch state.info.mockBuildVariant {
                            case .useActual: break
                            case .simulate(let value): await self?.buildVariantStream.send(value)
                        }
                    }
                    
                    if state.info.mockOriginatingAccount != state.previousInfo?.mockOriginatingAccount {
                        switch state.info.mockOriginatingAccount {
                            case .useActual: break
                            case .simulate(let value): await self?.originatingAccountStream.send(value)
                        }
                    }
                    
                    if state.info.mockRefundingStatus != state.previousInfo?.mockRefundingStatus {
                        switch state.info.mockRefundingStatus {
                            case .useActual: break
                            case .simulate(let value): await self?.refundingStatusStream.send(value)
                        }
                    }
                    
                    if state.info.mockAccessExpiryTimestamp != state.previousInfo?.mockAccessExpiryTimestamp {
                        if state.info.mockAccessExpiryTimestamp > 0 {
                            await self?.accessExpiryTimestampMsStream.send(UInt64(state.info.mockAccessExpiryTimestamp))
                        }
                    }
                }
            }
    }
    
    private func mockedIfNeeded(_ value: SessionPro.LoadingState) -> SessionPro.LoadingState {
        switch dependencies[feature: .mockCurrentUserSessionProLoadingState] {
            case .simulate(let mockedValue): return mockedValue
            case .useActual: return value
        }
    }
    
    private func mockedIfNeeded(_ value: Network.SessionPro.BackendUserProStatus) -> Network.SessionPro.BackendUserProStatus {
        switch dependencies[feature: .mockCurrentUserSessionProBackendStatus] {
            case .simulate(let mockedValue): return mockedValue
            case .useActual: return value
        }
    }
    
    private func mockedIfNeeded(_ value: SessionProUI.ClientPlatform) -> SessionProUI.ClientPlatform {
        switch dependencies[feature: .mockCurrentUserSessionProOriginatingPlatform] {
            case .simulate(let mockedValue): return mockedValue
            case .useActual: return value
        }
    }
    
    private func mockedIfNeeded(_ value: SessionPro.RefundingStatus) -> SessionPro.RefundingStatus {
        switch dependencies[feature: .mockCurrentUserSessionProRefundingStatus] {
            case .simulate(let mockedValue): return mockedValue
            case .useActual: return value
        }
    }
    
    private func mockedIfNeeded(_ value: UInt64?) -> UInt64? {
        let mockedValue: TimeInterval = dependencies[feature: .mockCurrentUserAccessExpiryTimestamp]
        
        guard mockedValue > 0 else { return value }
        
        return UInt64(mockedValue)
    }
}
