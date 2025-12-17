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
    private var revocationListTask: Task<Void, Never>?
    private var transactionObservingTask: Task<Void, Never>?
    private var entitlementsObservingTask: Task<Void, Never>?
    private var proMockingObservationTask: Task<Void, Never>?
    
    private var isRefreshingState: Bool = false
    private var rotatingKeyPair: KeyPair?
    
    nonisolated private let stateStream: CurrentValueAsyncStream<SessionPro.State> = CurrentValueAsyncStream(.invalid)
    
    nonisolated public var currentUserCurrentRotatingKeyPair: KeyPair? { syncState.rotatingKeyPair }
    nonisolated public var currentUserCurrentProState: SessionPro.State { syncState.state }
    nonisolated public var currentUserIsCurrentlyPro: Bool { syncState.state.status == .active }
    
    nonisolated public var pinnedConversationLimit: Int { SessionPro.PinnedConversationLimit }
    nonisolated public var characterLimit: Int {
        (currentUserIsCurrentlyPro ? SessionPro.ProCharacterLimit : SessionPro.CharacterLimit)
    }
    
    nonisolated public var state: AsyncStream<SessionPro.State> { stateStream.stream }
    nonisolated public var currentUserIsPro: AsyncStream<Bool> {
        stateStream.stream
            .map { $0.status == .active }
            .asAsyncStream()
    }
    
    // MARK: - Initialization
    
    public init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.syncState = SessionProManagerSyncState(using: dependencies)
        
        Task.detached(priority: .medium) { [weak self] in
            await self?.updateWithLatestFromUserConfig()
            await self?.startRevocationListTask()
            await self?.startStoreKitObservations()
            await self?.startProMockingObservations()
            
            /// Kick off a refresh so we know we have the latest state (if it's the main app)
            if dependencies[singleton: .appContext].isMainApp {
                try? await self?.refreshProState()
            }
        }
    }
    
    deinit {
        revocationListTask?.cancel()
        transactionObservingTask?.cancel()
        entitlementsObservingTask?.cancel()
        proMockingObservationTask?.cancel()
    }
    
    // MARK: - Functions
    
    nonisolated public func numberOfCharactersLeft(for content: String) -> Int {
        let features: SessionPro.FeaturesForMessage = messageFeatures(for: content)
        
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
    
    nonisolated public func messageFeatures(for message: String) -> SessionPro.FeaturesForMessage {
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
    
    nonisolated public func profileFeatures(for profile: Profile?) -> SessionPro.ProfileFeatures {
        guard syncState.dependencies[feature: .sessionProEnabled] else { return .none }
        guard let profile else {
            /// If we are forcing the pro badge to appear everywhere then insert it
            if syncState.dependencies[feature: .proBadgeEverywhere] {
                return .proBadge
            }
            
            return .none
        }
        
        var result: SessionPro.ProfileFeatures = profile.proFeatures
        
        /// Check if the pro status on the profile has expired (if so clear the features)
        switch (profile.proGenIndexHashHex, profile.proExpiryUnixTimestampMs) {
            case (.some(let proGenIndexHashHex), let expiryUnixTimestampMs) where expiryUnixTimestampMs > 0:
                // TODO: [PRO] Need to check the `proGenIndexHashHex` against the revocation list to see if the user still has pro
                let proWasRevoked: Bool = false
                let proHasExpired: Bool = (syncState.dependencies.dateNow.timeIntervalSince1970 > (Double(expiryUnixTimestampMs) / 1000))
                
                if proWasRevoked || proHasExpired {
                    result = .none
                }
                
                
            /// If we don't have either `proExpiryUnixTimestampMs` or `proGenIndexHashHex` then the pro state is invalid
            /// so the user shouldn't have any pro features
            default: result = .none
        }
        
        /// If we are forcing the pro badge to appear everywhere then insert it
        if syncState.dependencies[feature: .proBadgeEverywhere] {
            result.insert(.proBadge)
        }
        
        return result
    }
    
    nonisolated public func attachProInfoIfNeeded(message: Message) -> Message {
        let featuresForMessage: SessionPro.FeaturesForMessage = messageFeatures(
            for: ((message as? VisibleMessage)?.text ?? "")
        )
        let profileFeatures: SessionPro.ProfileFeatures = syncState.state.profileFeatures
        
        /// We only want to attach the `proFeatures` and `proProof` if a pro feature is _actually_ used
        guard
            featuresForMessage.status == .success, (
                profileFeatures != .none ||
                featuresForMessage.features != .none
            ),
            let proof: Network.SessionPro.ProProof = syncState.state.proof
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
                guard syncState.state.status != .active else { return false }
                
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
    
    @MainActor public func showSessionProBottomSheetIfNeeded(
        afterClosed: (() -> Void)?,
        presenting: ((UIViewController) -> Void)?
    ) {
        let viewModel: SessionProSettingsViewModel = SessionProSettingsViewModel(
            isInBottomSheet: true,
            using: syncState.dependencies
        )
        let sessionProBottomSheet: BottomSheetHostingViewController = BottomSheetHostingViewController(
            bottomSheet: BottomSheet(
                hasCloseButton: true,
                afterClosed: afterClosed
            ) {
                SessionListScreen(viewModel: viewModel)
            }
        )
        presenting?(sessionProBottomSheet)
    }
    
    public func sessionProExpiringCTAInfo() async -> (variant: ProCTAModal.Variant, paymentFlow: SessionProPaymentScreenContent.SessionProPlanPaymentFlow, planInfo: [SessionProPaymentScreenContent.SessionProPlanInfo])? {
        let state: SessionPro.State = await stateStream.getCurrent()
        let dateNow: Date = dependencies.dateNow
        let expiryInSeconds: TimeInterval = (state.accessExpiryTimestampMs
            .map { Date(timeIntervalSince1970: (Double($0) / 1000)).timeIntervalSince(dateNow) } ?? 0)
        let variant: ProCTAModal.Variant
        
        switch (state.status, state.autoRenewing, state.refundingStatus) {
            case (.neverBeenPro, _, _), (.active, _, .refunding), (.active, true, .notRefunding): return nil
            case (.active, false, .notRefunding):
                guard expiryInSeconds <= 7 * 24 * 60 * 60 else { return nil }
                
                variant = .expiring(
                    timeLeft: expiryInSeconds.formatted(
                        format: .long,
                        allowedUnits: [ .day, .hour, .minute ]
                    )
                )
                
            case (.expired, _, _):
                guard expiryInSeconds <= 30 * 24 * 60 * 60 else { return nil }
                
                variant = .expiring(timeLeft: nil)
        }
        
        // TODO: [PRO] Do we need to remove this flag if it's re-purchased or extended?
        guard !dependencies[defaults: .standard, key: .hasShownProExpiringCTA] else { return nil }
        
        let paymentFlow: SessionProPaymentScreenContent.SessionProPlanPaymentFlow = SessionProPaymentScreenContent.SessionProPlanPaymentFlow(state: state)
        let planInfo: [SessionProPaymentScreenContent.SessionProPlanInfo] = state.plans.map { SessionProPaymentScreenContent.SessionProPlanInfo(plan: $0) }
        
        return (variant, paymentFlow, planInfo)
    }
    
    // MARK: - State Management
    
    public func updateWithLatestFromUserConfig() async {
        if #available(iOS 16.0, *) {
            do { try await dependencies.waitUntilInitialised(cache: .libSession) }
            catch { return Log.error(.sessionPro, "Failed to wait until libSession initialised: \(error)") }
        }
        else {
            /// iOS 15 doesn't support dependency observation so work around it with a loop
            while true {
                try? await Task.sleep(for: .milliseconds(500))
                
                /// If `libSession` has data we can stop waiting
                if !dependencies[cache: .libSession].isEmpty {
                    break
                }
            }
        }
        
        /// Get the cached pro state from libSession
        typealias ProInfo = (
            proConfig: SessionPro.ProConfig?,
            profile: Profile,
            accessExpiryTimestampMs: UInt64
        )
        let proInfo: ProInfo = dependencies.mutate(cache: .libSession) {
            ($0.proConfig, $0.profile, $0.proAccessExpiryTimestampMs)
        }
        
        let rotatingKeyPair: KeyPair? = try? proInfo.proConfig.map { config in
            guard config.rotatingPrivateKey.count >= 32 else { return nil }
            
            return try dependencies[singleton: .crypto].tryGenerate(
                .ed25519KeyPair(seed: config.rotatingPrivateKey.prefix(upTo: 32))
            )
        }
        
        /// Infer the `proStatus` based on the config state (since we don't sync the status)
        let proStatus: Network.SessionPro.BackendUserProStatus = {
            guard let proof: Network.SessionPro.ProProof = proInfo.proConfig?.proProof else {
                return .neverBeenPro
            }
            
            let proofIsActive: Bool = proProofIsActive(
                for: proof,
                atTimestampMs: dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
            )
            return (proofIsActive ? .active : .expired)
        }()
        let oldState: SessionPro.State = await stateStream.getCurrent()
        let updatedState: SessionPro.State = oldState.with(
            status: .set(to: proStatus),
            proof: .set(to: proInfo.proConfig?.proProof),
            profileFeatures: .set(to: proInfo.profile.proFeatures),
            accessExpiryTimestampMs: .set(to: proInfo.accessExpiryTimestampMs),
            using: dependencies
        )
        
        /// Store the updated events and emit updates
        self.syncState.update(
            rotatingKeyPair: .set(to: rotatingKeyPair),
            state: .set(to: updatedState)
        )
        self.rotatingKeyPair = rotatingKeyPair
        await self.stateStream.send(updatedState)
        
        /// If the `accessExpiryTimestampMs` value changed then we should trigger a refresh because it generally means that
        /// other device did something that should refresh the pro state
        if updatedState.accessExpiryTimestampMs != oldState.accessExpiryTimestampMs {
            try? await refreshProState()
        }
    }
    
    public func purchasePro(productId: String) async throws {
        // TODO: [PRO] Show a modal indicating that we are doing a "DEV" purchase when on the simulator
        guard !dependencies[feature: .fakeAppleSubscriptionForDev] else {
            let bytes: [UInt8] = try dependencies[singleton: .crypto].tryGenerate(.randomBytes(8))
            return try await addProPayment(transactionId: "DEV.\(bytes.toHexString())") // stringlint:ignore
        }
        
        let state: SessionPro.State = await stateStream.getCurrent()
        
        guard let product: Product = state.products.first(where: { $0.id == productId }) else {
            Log.error(.sessionPro, "Attempted to purchase invalid product: \(productId)")
            throw SessionProError.productNotFound
        }
        
        let result: Product.PurchaseResult = try await product.purchase()
        
        guard case .success(let verificationResult) = result else {
            switch result {
                case .success: throw SessionProError.unhandledBehaviour  /// Invalid case
                case .pending:
                    // TODO: [PRO] Need to handle this case, new designs are now available (the `transactionObservingTask` will detect this case)
                    throw SessionProError.unhandledBehaviour
                    
                case .userCancelled: throw SessionProError.purchaseCancelled
                    
                @unknown default:
                    Log.critical(.sessionPro, "An unhandled purchase result was received: \(result)")
                    throw SessionProError.unhandledBehaviour
            }
        }
        
        let transaction: Transaction = try verificationResult.payloadValue
        
        /// There is a race condition where the client can try to register their payment before the Pro Backend has received the notification
        /// from Apple that the payment has happened, due to this we need to try add the payment a few times with a small delay before
        /// considering it an actual failure
        let maxRetries: Int = 3
        
        for index in 1...maxRetries {
            do {
                try await addProPayment(transactionId: "\(transaction.id)")
                break   /// Successfully registered the payment with the backend so no need to retry
            }
            catch {
                /// If we reached the last retry then throw the error
                if index == maxRetries {
                    Log.error(.sessionPro, "Failed to notify Pro backend of purchase due to error(s): \(error)")
                    throw error
                }
                
                /// Small incremental backoff before trying again
                try await Task.sleep(for: .milliseconds(index * 300))
            }
        }
        await transaction.finish()
    }
    
    public func addProPayment(transactionId: String) async throws {
        // TODO: [PRO] Need to sort out logic for rotating this key pair.
        /// First we need to add the pro payment to the Pro backend
        let rotatingKeyPair: KeyPair = try (
            self.rotatingKeyPair ??
            dependencies[singleton: .crypto].tryGenerate(.ed25519KeyPair())
        )
        let request = try Network.SessionPro.addProPayment(
            transactionId: transactionId,
            masterKeyPair: try dependencies[singleton: .crypto].tryGenerate(.sessionProMasterKeyPair()),
            rotatingKeyPair: rotatingKeyPair,
            requestTimeout: 5,  /// 5s timeout as per PRD
            using: dependencies
        )
        // FIXME: Make this async/await when the refactored networking is merged
        let response: Network.SessionPro.AddProPaymentOrGenerateProProofResponse = try await request
            .send(using: dependencies)
            .values
            .first(where: { _ in true })?.1 ?? { throw NetworkError.invalidResponse }()
        
        guard response.header.errors.isEmpty else {
            // TODO: [PRO] Need to show the error modal
            let errorString: String = response.header.errors.joined(separator: ", ")
            throw SessionProError.purchaseFailed(errorString)
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
        let oldState: SessionPro.State = await stateStream.getCurrent()
        let updatedState: SessionPro.State = oldState.with(
            status: .set(to: proStatus),
            proof: .set(to: response.proof),
            using: dependencies
        )
        
        syncState.update(
            rotatingKeyPair: .set(to: rotatingKeyPair),
            state: .set(to: updatedState)
        )
        self.rotatingKeyPair = rotatingKeyPair
        await self.stateStream.send(updatedState)
        
        /// Just in case we refresh the pro state (this will avoid needless requests based on the current state but will resolve other
        /// edge-cases since it's the main driver to the Pro state)
        try? await refreshProState()
    }
    
    // MARK: - Pro State Management
    
    private func updateProState(to newState: SessionPro.State) async {
        syncState.update(state: .set(to: newState))
        await self.stateStream.send(newState)
    }
    
    public func refreshProState(forceLoadingState: Bool) async throws {
        /// No point refreshing the state if there is a refresh in progress
        guard !isRefreshingState else { return }
        
        isRefreshingState = true
        defer { isRefreshingState = false }
        
        /// Only reset the `loadingState` if it's currently in an error state
        var oldState: SessionPro.State = await stateStream.getCurrent()
        var updatedState: SessionPro.State = oldState
        
        if forceLoadingState || oldState.loadingState == .error {
            updatedState = oldState.with(
                loadingState: .set(to: .loading),
                using: dependencies
            )
            
            syncState.update(state: .set(to: updatedState))
            await self.stateStream.send(updatedState)
            oldState = updatedState
        }
        
        /// Get the product list from the AppStore first (need this to populate the UI)
        if oldState.products.isEmpty || oldState.plans.isEmpty {
            let result: (products: [Product], plans: [SessionPro.Plan]) = try await SessionPro.Plan
                .retrieveProductsAndPlans()
            updatedState = oldState.with(
                products: .set(to: result.products),
                plans: .set(to: result.plans),
                using: dependencies
            )
            
            syncState.update(state: .set(to: updatedState))
            await self.stateStream.send(updatedState)
            oldState = updatedState
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
            
            updatedState = oldState.with(
                loadingState: .set(to: .error),
                using: dependencies
            )
            
            syncState.update(state: .set(to: updatedState))
            await self.stateStream.send(updatedState)
            throw SessionProError.getProDetailsFailed(errorString)
        }
        updatedState = oldState.with(
            status: .set(to: response.status),
            autoRenewing: .set(to: response.autoRenewing),
            accessExpiryTimestampMs: .set(to: response.expiryTimestampMs),
            latestPaymentItem: .set(to: response.items.first),
            using: dependencies
        )
        
        syncState.update(state: .set(to: updatedState))
        await self.stateStream.send(updatedState)
        oldState = updatedState
        
        switch response.status {
            case .active:
                try await refreshProProofIfNeeded(
                    currentProof: updatedState.proof,
                    accessExpiryTimestampMs: (updatedState.accessExpiryTimestampMs ?? 0),
                    autoRenewing: updatedState.autoRenewing,
                    status: updatedState.status
                )
                
            case .neverBeenPro: try await clearProProofFromConfig()
            case .expired: try await clearProProofFromConfig()
        }
        
        updatedState = oldState.with(
            loadingState: .set(to: .success),
            using: dependencies
        )
        
        syncState.update(state: .set(to: updatedState))
        await self.stateStream.send(updatedState)
        oldState = updatedState
    }
    
    public func refreshProProofIfNeeded(
        currentProof: Network.SessionPro.ProProof?,
        accessExpiryTimestampMs: UInt64,
        autoRenewing: Bool,
        status: Network.SessionPro.BackendUserProStatus
    ) async throws {
        guard status == .active else { return }
        
        let needsNewProof: Bool = {
            guard let currentProof else { return true }
            
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
            throw SessionProError.generateProProofFailed(errorString)
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
        let oldState: SessionPro.State = await stateStream.getCurrent()
        let updatedState: SessionPro.State = oldState.with(
            status: .set(to: proStatus),
            using: dependencies
        )
        
        syncState.update(
            rotatingKeyPair: .set(to: rotatingKeyPair),
            state: .set(to: updatedState)
        )
        self.rotatingKeyPair = rotatingKeyPair
        await self.stateStream.send(updatedState)
    }
    
    @MainActor public func cancelPro(scene: UIWindowScene) async throws {
        do {
            try await AppStore.showManageSubscriptions(in: scene)
            
            // TODO: [PRO] Is there anything else we need to do here? Can we detect what the user did? (eg. via the transaction observation or something similar)
            /// Need to refresh the pro state in case the user cancelled their pro (force the UI into the "loading" state just to be sure)
            try await refreshProState(forceLoadingState: true)
        }
        catch {
            throw SessionProError.failedToShowStoreKitUI("Manage Subscriptions")
        }
    }
    
    @MainActor public func requestRefund(scene: UIWindowScene) async throws {
        guard let latestPaymentItem: Network.SessionPro.PaymentItem = await stateStream.getCurrent().latestPaymentItem else {
            throw SessionProError.noLatestPaymentItem
        }
        
        /// User has already requested a refund for this item
        guard latestPaymentItem.refundRequestedTimestampMs == 0 else {
            throw SessionProError.refundAlreadyRequestedForLatestPayment
        }
        
        /// Only Apple support refunding via this mechanism so no point continuing if we don't have a `appleTransactionId`
        guard let transactionId: String = latestPaymentItem.appleTransactionId else {
            throw SessionProError.nonOriginatedLatestPayment
        }
        
        /// If we don't have the `fakeAppleSubscriptionForDev` feature enabled then we need to actually request the refund from Apple
        if !syncState.dependencies[feature: .fakeAppleSubscriptionForDev] {
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
                throw SessionProError.transactionNotFound
            }
            
            let status: Transaction.RefundRequestStatus = try await targetTransaction.beginRefundRequest(in: scene)
            
            switch status {
                case .success: break    /// Continue on to send the refund to our backend
                case .userCancelled: throw SessionProError.refundCancelled
                @unknown default:
                    Log.critical(.sessionPro, "Unknown refund request status: \(status)")
                    throw SessionProError.unhandledBehaviour
            }
        }
        
        let refundRequestedTimestampMs: UInt64 = syncState.dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
        let request = try Network.SessionPro.setPaymentRefundRequested(
            transactionId: transactionId,
            refundRequestedTimestampMs: refundRequestedTimestampMs,
            masterKeyPair: try syncState.dependencies[singleton: .crypto].tryGenerate(.sessionProMasterKeyPair()),
            using: syncState.dependencies
        )
        
        // FIXME: Make this async/await when the refactored networking is merged
        let response: Network.SessionPro.SetPaymentRefundRequestedResponse = try await request
            .send(using: syncState.dependencies)
            .values
            .first(where: { _ in true })?.1 ?? { throw NetworkError.invalidResponse }()
        
        guard response.header.errors.isEmpty else {
            let errorString: String = response.header.errors.joined(separator: ", ")
            Log.error(.sessionPro, "Refund submission failed due to error(s): \(errorString)")
            throw SessionProError.refundFailed(errorString)
        }
        
        /// Need to refresh the pro state to get the updated payment item (which should now include a `refundRequestedTimestampMs`)
        try await refreshProState()
    }
        
    // MARK: - Internal Functions
    
    private func startRevocationListTask() {
        revocationListTask = Task {
            // TODO: [PRO] Need to add in the logic for fetching, storing and updating the revocation list
        }
    }
    
    private func startStoreKitObservations() {
        transactionObservingTask = Task {
            for await result in Transaction.updates {
                do {
                    switch result {
                        case .verified(let transaction):
                            // let transaction: Transaction = try result.payloadValue
                            // await transaction.finish()
                            // TODO: [PRO] Need to actually handle this case (send to backend)
                            break
                            
                        case .unverified(_, let error):
                            Log.error(.sessionPro, "Received an unverified transaction update: \(error)")
                    }
                    
                }
                catch {
                    Log.error(.sessionPro, "Failed to retrieve transaction from update: \(error)")
                }
            }
        }
        
        // TODO: [PRO] Do we want this to run in a loop with a sleep in case the user purchases pro on another device?
        entitlementsObservingTask = Task { [weak self] in
            guard let self else { return }
            
            var currentEntitledTransactions: [Transaction] = []
            
            for await result in Transaction.currentEntitlements {
                guard case .verified(let transaction) = result else { continue }
                
                /// Ensure it's a subscription product
                guard transaction.productType == .autoRenewable else { continue }
                
                currentEntitledTransactions.append(transaction)
            }
            
            let oldState: SessionPro.State = await stateStream.getCurrent()
            let updatedState: SessionPro.State = oldState.with(
                entitledTransactions: .set(to: currentEntitledTransactions),
                using: syncState.dependencies
            )
            await updateProState(to: updatedState)
        }
    }
    
    private func clearProProofFromConfig() async throws {
        try await dependencies[singleton: .storage].writeAsync { [dependencies] db in
            try dependencies.mutate(cache: .libSession) { cache in
                try cache.performAndPushChange(db, for: .userProfile) { _ in
                    cache.removeProConfig()
                }
            }
        }
    }
}

// MARK: - SyncState

private final class SessionProManagerSyncState {
    private let lock: NSLock = NSLock()
    private let _dependencies: Dependencies
    private var _rotatingKeyPair: KeyPair? = nil
    private var _state: SessionPro.State = .invalid
    
    fileprivate var dependencies: Dependencies { lock.withLock { _dependencies } }
    fileprivate var rotatingKeyPair: KeyPair? { lock.withLock { _rotatingKeyPair } }
    fileprivate var state: SessionPro.State { lock.withLock { _state } }
    
    fileprivate init(using dependencies: Dependencies) {
        self._dependencies = dependencies
    }
    
    fileprivate func update(
        rotatingKeyPair: Update<KeyPair?> = .useExisting,
        state: Update<SessionPro.State> = .useExisting
    ) {
        lock.withLock {
            self._rotatingKeyPair = rotatingKeyPair.or(self._rotatingKeyPair)
            self._state = state.or(self._state)
        }
    }
}

// MARK: - SessionProManagerType

public protocol SessionProManagerType: SessionProUIManagerType {
    nonisolated var characterLimit: Int { get }
    nonisolated var currentUserCurrentRotatingKeyPair: KeyPair? { get }
    nonisolated var currentUserCurrentProState: SessionPro.State { get }
    
    nonisolated var state: AsyncStream<SessionPro.State> { get }
    
    nonisolated func proStatus<I: DataProtocol>(
        for proof: Network.SessionPro.ProProof?,
        verifyPubkey: I?,
        atTimestampMs timestampMs: UInt64
    ) -> SessionPro.DecodedStatus?
    nonisolated func proProofIsActive(
        for proof: Network.SessionPro.ProProof?,
        atTimestampMs timestampMs: UInt64
    ) -> Bool
    nonisolated func messageFeatures(for message: String) -> SessionPro.FeaturesForMessage
    nonisolated func profileFeatures(for profile: Profile?) -> SessionPro.ProfileFeatures
    nonisolated func attachProInfoIfNeeded(message: Message) -> Message
    func sessionProExpiringCTAInfo() async -> (variant: ProCTAModal.Variant, paymentFlow: SessionProPaymentScreenContent.SessionProPlanPaymentFlow, planInfo: [SessionProPaymentScreenContent.SessionProPlanInfo])?
    
    // MARK: - State Management
    
    func updateWithLatestFromUserConfig() async
    
    func purchasePro(productId: String) async throws
    func addProPayment(transactionId: String) async throws
    func refreshProState(forceLoadingState: Bool) async throws
    @MainActor func requestRefund(scene: UIWindowScene) async throws
    @MainActor func cancelPro(scene: UIWindowScene) async throws
}

public extension SessionProManagerType {
    func refreshProState() async throws {
        try await refreshProState(forceLoadingState: false)
    }
}

// MARK: - Observations

// stringlint:ignore_contents
public extension ObservableKey {
    static func currentUserProState(_ manager: SessionProManagerType) -> ObservableKey {
        return ObservableKey.stream(
            key: "currentUserProState",
            generic: .currentUserProState
        ) { [weak manager] in manager?.state }
    }
}

// stringlint:ignore_contents
public extension GenericObservableKey {
    static let currentUserProState: GenericObservableKey = "currentUserProState"
}

// MARK: - Mocking

private extension SessionProManager {
    private func startProMockingObservations() {
        proMockingObservationTask = ObservationBuilder
            .initialValue(SessionPro.MockState(using: dependencies))
            .debounce(for: .milliseconds(10))
            .using(dependencies: dependencies)
            .query { previousState, _, _, dependencies in
                SessionPro.MockState(previousInfo: previousState.info, using: dependencies)
            }
            .assign { [weak self] state in
                Task.detached(priority: .userInitiated) {
                    /// If the entire Session Pro feature is disabled then clear any state
                    guard state.info.sessionProEnabled else {
                        self?.syncState.update(
                            rotatingKeyPair: .set(to: nil),
                            state: .set(to: .invalid)
                        )
                        
                        await self?.stateStream.send(.invalid)
                        return
                    }
                    
                    /// If we need a state refresh then start a new task to do so (we don't want the mocking to be dependant on the
                    /// result of the refresh so don't wait for it to complete before doing any mock changes)
                    if state.needsRefresh {
                        Task.detached { [weak self] in try await self?.refreshProState() }
                    }
                    
                    /// While it would be easier to just rely on `refreshProState` to update the mocked values, that would
                    /// mean the mocking requires network connectivity which isn't ideal, so we also explicitly send out any mock
                    /// changes separately
                    guard
                        let oldState: SessionPro.State = await self?.stateStream.getCurrent(),
                        let dependencies: Dependencies = self?.syncState.dependencies
                    else { return }
                    
                    let updatedState: SessionPro.State = oldState.with(using: dependencies)
                    self?.syncState.update(state: .set(to: updatedState))
                    await self?.stateStream.send(updatedState)
                }
            }
    }
}
