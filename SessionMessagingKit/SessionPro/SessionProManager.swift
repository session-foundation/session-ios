// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import StoreKit
import Combine
import SessionUtil
import SessionUIKit
import SessionNetworkingKit
import SessionUtilitiesKit

// MARK: - Singleton

public extension Singleton {
    static let sessionProManager: SingletonConfig<SessionProManagerType> = Dependencies.create(
        identifier: "sessionProManager",
        createInstance: { dependencies, _ in SessionProManager(using: dependencies) }
    )
}

// MARK: - SessionPro

public enum SessionPro {
    public static var CharacterLimit: Int { Int(SESSION_PROTOCOL_STANDARD_CHARACTER_LIMIT) }
    public static var ProCharacterLimit: Int { Int(SESSION_PROTOCOL_PRO_HIGHER_CHARACTER_LIMIT) }
    public static var PinnedConversationLimit: Int { Int(SESSION_PROTOCOL_STANDARD_PINNED_CONVERSATION_LIMIT) }
}

// MARK: - SessionProManager

public actor SessionProManager: SessionProManagerType {
    private let dependencies: Dependencies
    nonisolated private let syncState: SessionProManagerSyncState
    private var revocationListTask: Task<Void, Never>?
    private var transactionObservingTask: Task<Void, Never>?
    private var entitlementsObservingTask: Task<Void, Never>?
    private var proMockingObservationTask: Task<Void, Never>?
    private var proInvalidationTask: Task<Void, Never>?
    private var appLifecycleObservingTask: Task<Void, Never>?

    /// Proof-renewal reconcile loop (Rev 2). `proofRenewalWakeTask` is the advisory in-foreground wake;
    /// `proofGenerationTask` is the in-flight `generate_pro_proof`. `lastProofRequestAt` + `darkAttempt`
    /// are ephemeral spacing/backoff state (re-derived from config each pass, reset on process death).
    private var proofRenewalWakeTask: Task<Void, Never>?
    private var proofGenerationTask: Task<Void, Never>?
    private var postPurchaseStatusPollTask: Task<Void, Never>?
    private var lastProofRequestAt: TimeInterval = -.greatestFiniteMagnitude
    private var darkAttempt: Int = 0

    /// The instant up to which we have already emitted "this profile's pro state just went stale" events
    ///
    /// Used as the lower bound of the window in `emitProInvalidationEvents(since:until:)` so that each lapse is emitted exactly
    /// once, and so a lapse that happened while the app was suspended is still caught on the next evaluation
    private var lastProInvalidationCheck: TimeInterval = 0

    private var isRefreshingState: Bool = false
    private var rotatingKeyPair: KeyPair?
    
    nonisolated private let stateStream: CurrentValueAsyncStream<SessionPro.State> = CurrentValueAsyncStream(.invalid)
    nonisolated private let hasCompletedInitialization: CurrentValueAsyncStream<Bool> = CurrentValueAsyncStream(false)
    
    nonisolated public var currentUserCurrentRotatingKeyPair: KeyPair? { syncState.rotatingKeyPair }
    nonisolated public var currentUserCurrentProState: SessionPro.State { syncState.state }
    nonisolated public var currentUserIsCurrentlyPro: Bool { syncState.state.status == .active }

    nonisolated public var pinnedConversationLimit: Int { SessionPro.PinnedConversationLimit }
    nonisolated public var characterLimit: Int {
        (
            currentUserIsCurrentlyPro ?
                SessionPro.ProCharacterLimit :
                SessionPro.CharacterLimit
        )
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
            await self?.startProMockingObservations()

            await self?.updateWithLatestFromUserConfig()
            await self?.startRevocationListTask()
            await self?.startStoreKitObservations()
            await self?.startProInvalidationRescheduleObservations()
            await self?.scheduleNextProInvalidation()
            
            /// Kick off a refresh so we know we have the latest state (if it's the main app)
            if dependencies[singleton: .appContext].isMainApp {
                try? await self?.refreshProState()
            }

            /// Kick the foreground-anchored proof-renewal reconcile (main-app-gated inside)
            await self?.reconcileProofRenewal()

            await self?.hasCompletedInitialization.send(true)
        }
    }
    
    deinit {
        revocationListTask?.cancel()
        transactionObservingTask?.cancel()
        entitlementsObservingTask?.cancel()
        proMockingObservationTask?.cancel()
        proInvalidationTask?.cancel()
        appLifecycleObservingTask?.cancel()
        proofRenewalWakeTask?.cancel()
        proofGenerationTask?.cancel()
        postPurchaseStatusPollTask?.cancel()
    }
    
    public func ensureInitialized() async {
        guard await !hasCompletedInitialization.getCurrent() else { return }

        _ = await hasCompletedInitialization.stream.first(where: { $0 })
    }
    
    // MARK: - Functions
    
    nonisolated public func numberOfCharactersLeft(for content: String) -> Int {
        /// Count Unicode codepoints natively — for a (always valid) Swift `String`,
        /// `unicodeScalars.count` is the codepoint count (surrogate pair = 1), matching what libsession's
        /// simdutf path produced. No round-trip into libsession just to count.
        return (characterLimit - content.unicodeScalars.count)
    }
    
    nonisolated public func proProofIsActive(
        for proof: Network.SessionPro.ProProof?,
        atTimestampMs timestampMs: UInt64
    ) -> Bool {
        guard let proof: Network.SessionPro.ProProof else { return false }

        var cProProof: session_protocol_pro_proof = proof.libSessionValue

        return session_protocol_pro_proof_is_active(&cProProof, Int64(timestampMs / 1000))
    }

    /// Whether the current user's own cached proof is usable for attaching to a message (Rev 2 §6.1
    /// validity): present, unexpired, AND not on the revocation list. `proProofIsActive` covers only expiry,
    /// so this adds the revocation check (a revoked-but-unexpired proof must never be attached).
    nonisolated public func currentUserProofIsValid(atTimestampMs timestampMs: UInt64) -> Bool {
        guard
            let proof: Network.SessionPro.ProProof = syncState.state.proof,
            proProofIsActive(for: proof, atTimestampMs: timestampMs)
        else { return false }

        let nowSeconds: TimeInterval = TimeInterval(timestampMs / 1000)
        let proofRevocationTagHex: String = proof.revocationTag.toHexString()
        let isRevoked: Bool = syncState.revocationList.contains { item in
            TimeInterval(item.effectiveTimestampSeconds) <= nowSeconds &&
            item.revocationTag.toHexString() == proofRevocationTagHex
        }

        return !isRevoked
    }
    
    nonisolated public func messageFeatures(for message: String) -> SessionPro.FeaturesForMessage {
        /// libsession no longer inspects the text — we pass the natively-counted codepoint count
        /// (`unicodeScalars.count`) and it returns the required feature bitset + limit status.
        return SessionPro.FeaturesForMessage(
            session_protocol_pro_features_for_message(message.unicodeScalars.count)
        )
    }
    
    nonisolated public func profileFeatures(for profile: Profile?) -> SessionPro.ProfileFeatures {
        guard let profile else {
            /// If we are forcing the pro badge to appear everywhere then insert it
            if syncState.dependencies[feature: .proBadgeEverywhere] {
                return .proBadge
            }
            
            return .none
        }
        
        var result: SessionPro.ProfileFeatures = profile.proFeatures
        let currentUserSessionId: SessionId = syncState.dependencies[cache: .general].sessionId
        
        /// Check if the pro status on the profile has expired (if so clear the features)
        switch (profile.proRevocationTagHex, profile.proExpiryUnixTimestampSeconds, profile.id == currentUserSessionId.hexString) {
            case (_, _, true):
                if !currentUserIsCurrentlyPro {
                    result = .none
                }
            case (.some(let proRevocationTagHex), let expiryUnixTimestampSeconds, _) where expiryUnixTimestampSeconds > 0:
                /// **Note:** A revocation item only takes effect once our clock reaches its `effectiveTimestampSeconds`, the backend
                /// can publish a revocation ahead of time so we need to keep honouring the proof until that instant passes
                let nowTimestampSeconds: TimeInterval = syncState.dependencies.dateNow.timeIntervalSince1970
                let proWasRevoked: Bool = syncState.revocationList.contains { item in
                    TimeInterval(item.effectiveTimestampSeconds) <= nowTimestampSeconds &&
                    item.revocationTag.toHexString() == proRevocationTagHex
                }
                let proHasExpired: Bool = (nowTimestampSeconds > TimeInterval(expiryUnixTimestampSeconds))

                if proWasRevoked || proHasExpired {
                    result = .none
                }

            /// If we don't have either `proExpiryUnixTimestampSeconds` or `proRevocationTagHex` then the pro state is invalid
            /// so the user shouldn't have any pro features
            default: result = .none
        }
        
        /// If we are forcing the pro badge to appear everywhere then insert it
        if syncState.dependencies[feature: .proBadgeEverywhere] {
            result.insert(.proBadge)
        }
        
        return result
    }
    
    nonisolated public func messageProFeatureList(_ features: SessionPro.MessageFeatures) -> SessionPro.MessageFeatures {
        let updatedFeatures: SessionPro.MessageFeatures = features
        
        if syncState.dependencies[feature: .forceMessageFeatureLongMessage] {
            return updatedFeatures.union(.largerCharacterLimit)
        }

        return updatedFeatures
    }
    
    nonisolated public func profileProFeatureList(_ features: SessionPro.ProfileFeatures) -> SessionPro.ProfileFeatures {
        var updatedFeatures: SessionPro.ProfileFeatures = features
        
        if syncState.dependencies[feature: .forceMessageFeatureProBadge] {
            updatedFeatures.insert(.proBadge)
        }

        if syncState.dependencies[feature: .forceMessageFeatureAnimatedAvatar] {
            updatedFeatures.insert(.animatedAvatar)
        }
        
        return updatedFeatures
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
            let proof: Network.SessionPro.ProProof = syncState.state.proof,
            /// Send rule §6.1: a message carries a currently-VALID proof or NONE — never expired OR revoked.
            /// Sending is never blocked by a lapsed proof (the message just goes out without Pro metadata);
            /// Pro-*requiring* compose gating lives elsewhere and keys off subscription status, not the proof.
            currentUserProofIsValid(atTimestampMs: syncState.dependencies.networkOffsetTimestampMs())
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
        switch variant {
            /// The `groupLimit`, `animatedProfileImage`, and `expiring` CTA can be shown for Session Pro users as well
            case .groupLimit, .animatedProfileImage, .expiring: break
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
        
        // Note: We have to make sure the initial pro status loading is finished, otherwise the pro status info and plan info
        // may not be correct
        await ensureInitialized()

        let state: SessionPro.State = await stateStream.getCurrent()

        /// Never fire an expiring/expired CTA off unconfirmed status. At (cold) launch `status` is inferred
        /// from the LOCAL proof, so a single-device account whose subscription renewed while the app was
        /// closed always looks `.expired` locally until a `get_pro_status` succeeds (there's no config write
        /// at renewal to correct it). Firing here would flash a false "Pro expired". Gate on a confirmed
        /// fetch (`.success`) — on `.loading`/`.error` we return `nil` and a later successful refresh
        /// (foreground reconcile) re-triggers the CTA if the subscription genuinely lapsed.
        guard state.loadingState == .success else { return nil }
        let dateNow: Date = dependencies.dateNow
        let expiryInSeconds: TimeInterval = (state.accessExpiryTimestampSeconds
            .map { Date(timeIntervalSince1970: Double($0)).timeIntervalSince(dateNow) } ?? 0)
        let variant: ProCTAModal.Variant
        
        switch (state.status, state.autoRenewing, state.refundingStatus) {
            // Fail closed: an unrecognised backend status behaves like `.never` (no CTA, no Pro).
            case (.never, _, _), (.unknown, _, _), (.active, _, .refunding), (.active, true, .notRefunding): return nil
            case (.active, false, .notRefunding):
                guard
                    expiryInSeconds <= 7 * 24 * 60 * 60 &&
                    !dependencies[defaults: .standard, key: .hasShownProExpiringCTA]
                else { return nil }
                
                variant = .expiring(
                    timeLeft: expiryInSeconds.formatted(
                        format: .long,
                        allowedUnits: [ .day, .hour, .minute ]
                    )
                )
                
            case (.expired, _, _):
                guard
                    expiryInSeconds <= 30 * 24 * 60 * 60 &&
                    !dependencies[defaults: .standard, key: .hasShownProExpiredCTA]
                else { return nil }
                
                variant = .expiring(timeLeft: nil)
        }
        
        let paymentFlow: SessionProPaymentScreenContent.SessionProPlanPaymentFlow = SessionProPaymentScreenContent.SessionProPlanPaymentFlow(state: state)
        let planInfo: [SessionProPaymentScreenContent.SessionProPlanInfo] = state.plans.map { SessionProPaymentScreenContent.SessionProPlanInfo(plan: $0) }
        
        return (variant, paymentFlow, planInfo)
    }
    
    // MARK: - State Management
    
    public func updateWithLatestFromUserConfig() async {
        await dependencies.untilInitialised(cache: .libSession)
        
        /// Get the cached pro state from libSession
        typealias ProInfo = (
            proConfig: SessionPro.ProConfig?,
            profile: Profile,
            accessExpiryTimestampSeconds: UInt64,
            refundRequestedTimestampSeconds: UInt64,
            prepaidTimestampSeconds: UInt64
        )
        let proInfo: ProInfo = dependencies.mutate(cache: .libSession) {
            ($0.proConfig, $0.profile, $0.proAccessExpiryTimestampSeconds, $0.refundRequestedTimestampSeconds, $0.proPrepaidTimestampSeconds)
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
                return .never
            }
            
            let proofIsActive: Bool = proProofIsActive(
                for: proof,
                atTimestampMs: dependencies.networkOffsetTimestampMs()
            )
            return (proofIsActive ? .active : .expired)
        }()
        let oldState: SessionPro.State = await stateStream.getCurrent()
        let updatedState: SessionPro.State = oldState.with(
            status: .set(to: proStatus),
            proof: .set(to: proInfo.proConfig?.proProof),
            profileFeatures: .set(to: proInfo.profile.proFeatures),
            accessExpiryTimestampSeconds: .set(to: proInfo.accessExpiryTimestampSeconds),
            refundRequestedTimestampSeconds: .set(to: proInfo.refundRequestedTimestampSeconds),
            using: dependencies
        )

        /// Store the updated events and emit updates
        self.syncState.update(
            rotatingKeyPair: .set(to: rotatingKeyPair),
            state: .set(to: updatedState)
        )
        self.rotatingKeyPair = rotatingKeyPair
        await self.stateStream.send(updatedState)

        /// If the `accessExpiryTimestampSeconds` value changed then we should trigger a refresh because it generally means that
        /// other device did something that should refresh the pro state
        if updatedState.accessExpiryTimestampSeconds != oldState.accessExpiryTimestampSeconds {
            try? await refreshProState()

            await dependencies.notify(
                key: .proAccessExpiryUpdated,
                value: proInfo.accessExpiryTimestampSeconds
            )
        }

        /// Reconcile against the (possibly cross-device-updated) proof / prepaid marker / renewal target. A
        /// pending purchase (`pro_prepaid` set, synced from another device) now surfaces as
        /// `renewal_target <= now` via the gate, so the reconcile's dark path IS the acquisition poll — no
        /// separate prepaid poll.
        await reconcileProofRenewal()
    }
    
    public func purchasePro(productId: String) async throws {
        guard !dependencies[feature: .fakeAppleSubscriptionForDev] else {
            /// Dev shortcut: skip StoreKit and just mark the purchase in-flight, then let the reconcile loop
            /// pull the entitlement through (redemption is implicit — there's no add-payment call).
            try await markPurchaseInFlight()
            await reconcileProofRenewal()
            startPostPurchaseStatusPoll()
            return
        }

        let state: SessionPro.State = await stateStream.getCurrent()

        guard let product: Product = state.products.first(where: { $0.id == productId }) else {
            Log.error(.sessionPro, "Attempted to purchase invalid product: \(productId)")
            throw SessionProError.productNotFound
        }

        /// Attach a deterministic `appAccountToken` derived from the Pro master public key so the Pro backend can
        /// cryptographically bind this Apple payment to the master key (rather than trusting the transaction id to
        /// stay secret). This is mandatory — proceeding without it would leave the payment claimable by anyone who
        /// learns the transaction id.
        let appleAccountToken: UUID = try dependencies[singleton: .crypto]
            .tryGenerate(.sessionProAppleAccountToken())
        let options: Set<Product.PurchaseOption> = [ .appAccountToken(appleAccountToken) ]
        let result: Product.PurchaseResult = try await product.purchase(options: options)

        guard case .success(let verificationResult) = result else {
            switch result {
                case .success: throw SessionProError.unhandledBehaviour  /// Invalid case
                case .pending: throw SessionProError.purchasePending
                case .userCancelled: throw SessionProError.purchaseCancelled

                @unknown default:
                    Log.critical(.sessionPro, "An unhandled purchase result was received: \(result)")
                    throw SessionProError.unhandledBehaviour
            }
        }

        let transaction: Transaction = try verificationResult.payloadValue

        /// Apple accepted the payment (the verified transaction). Redemption is implicit: there is no
        /// `/add_pro_payment` any more — the backend binds the account's unbound payments on any
        /// master-signed request, and it learns of the payment from Apple, not from us.
        ///
        /// Record the "purchase in flight" marker in config FIRST, then `finish()`. `finish()` has no effect
        /// on the payment — it only stops StoreKit redelivering the transaction via `Transaction.updates` —
        /// so we defer it until our state is durably recorded: `markPurchaseInFlight` awaits the config
        /// write, whose libsession dump is persisted to the local DB synchronously (the durable point). If
        /// we crashed before that, StoreKit would re-hand us the transaction and we'd retry. Then the
        /// reconcile loop (dark path) requests a proof via `generate_pro_proof`, binding the payment.
        try await markPurchaseInFlight()
        await transaction.finish()
        await reconcileProofRenewal()
        startPostPurchaseStatusPoll()
    }

    /// After a StoreKit purchase, chase the ACCOUNT expiry (`E`) via `get_pro_status` rather than forcing
    /// a proof rotation. When the user re-subscribes while a still-valid (grace) proof is held,
    /// `pro_renewal_target` returns `nullopt` (correctly: rotating the proof early would leak the
    /// subscription change via the rotating seed, so the current proof is ridden until it nears expiry)
    /// and `pro_prepaid` is a no-op (already entitled) — so nothing else re-fetches, and the new
    /// subscription period would stay invisible until the proof eventually lapses. The backend learns of
    /// the payment from Apple asynchronously, so a one-shot refresh usually fires too early; re-fetch
    /// `get_pro_status` until `E` advances (the new period landing) or it's been ≥2 min since the first
    /// request. The first refresh is immediate — onion-request latency means Apple has very often already
    /// notified the backend by the time our request arrives.
    ///
    /// Pacing is off COMPLETION, not a fixed cadence: a fresh `get_pro_status` is an onion request that can
    /// take a while (or time out ~30s), so we fire, AWAIT the result (fresh response, or failure/timeout),
    /// then apply a 5s gap before the next — never a new request while one is in flight. The sequential
    /// `await` gives this for free. The 2-min window is measured from the first request; a request already
    /// in flight when it elapses finishes, we just don't start new ones. (The per-request onion timeout is
    /// the "never settles" backstop — a single `refreshProState` can't hang indefinitely.) Matches
    /// Android's 2-min window / 5s-gap-after-settle pacing.
    ///
    /// Note we route through `get_pro_status`, not a direct proof-gen: each refresh's `E` write feeds the
    /// trailing `reconcileProofRenewal`, so a fresh proof IS fetched *if and when* `pro_renewal_target`
    /// says one is due (e.g. the proof was actually expired) and is correctly left alone when it isn't (the
    /// grace re-subscribe case). We avoid forcing an early/unnecessary (seed-leaking) rotation — not proof
    /// updates altogether.
    private func startPostPurchaseStatusPoll() {
        postPurchaseStatusPollTask?.cancel()
        postPurchaseStatusPollTask = Task { [weak self] in
            guard let self else { return }

            let expiryBefore: UInt64 = (await self.stateStream.getCurrent().accessExpiryTimestampSeconds ?? 0)
            let startSeconds: Int64 = Int64(await self.dependencies.networkOffsetTimestampMs() / 1000)
            let windowSeconds: Int64 = 120   /// 2 minutes since the FIRST request

            while true {
                if Task.isCancelled { return }

                /// Fire and AWAIT settle (fresh response, or failure/timeout — `try?` swallows the throw).
                try? await self.refreshProState()

                let expiryNow: UInt64 = (await self.stateStream.getCurrent().accessExpiryTimestampSeconds ?? 0)
                if expiryNow > expiryBefore { return }   /// new period landed — done

                /// Stop kicking off new requests once ≥2 min since the first fire (the just-completed one
                /// was allowed to finish; we simply don't start another).
                let nowSeconds: Int64 = Int64(await self.dependencies.networkOffsetTimestampMs() / 1000)
                if (nowSeconds - startSeconds) >= windowSeconds { return }

                /// 5s gap BETWEEN completed attempts (not a fixed tick).
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
            }
        }
    }

    /// Records the "purchase in flight" marker in the synced user config so every device polls the
    /// entitlement through. A no-op in libsession if the account is already Pro, and cleared automatically
    /// once the entitlement lands.
    private func markPurchaseInFlight() async throws {
        let nowSeconds: UInt64 = (await dependencies.networkOffsetTimestampMs() / 1000)
        try await dependencies[singleton: .storage].write { [dependencies] db in
            try dependencies.mutate(cache: .libSession) { cache in
                try cache.performAndPushChange(db, for: .userProfile) { _ in
                    cache.updateProPrepaid(nowSeconds)
                }
            }
        }
    }

    // MARK: -- Proof Renewal (Rev 2 reconcile loop)

    /// The Session Pro proof-renewal reconcile loop — the cross-platform design-of-record (Rev 2 §2).
    ///
    /// `pro_renewal_target(now)` owns the whole decision (timing + entitlement/`pro_prepaid` gate; no client
    /// jitter or window math): `NONE`/`0` ⇒ DORMANT, a future ts ⇒ schedule a wake, `<= now` ⇒ a renewal or
    /// acquisition is due. The renewal ACTION is a pure `generate_pro_proof` (§1.3) — the response type +
    /// `account_expiry_ts` cover what a status fetch used to; `get_pro_status` (`refreshProState`) stays only
    /// for the auto-renew / grace / refund display fields.
    ///
    /// `lastProofRequestAt`, `darkAttempt`, and the wake are ephemeral (re-derived from config each pass), so
    /// suspension and process death both recover on the next reconcile. Single-flight is best-effort via the
    /// `lastProofRequestAt` spacing check; an overlap is accepted (§1.9 — the §4 monotonic merge makes a late
    /// duplicate a no-op: the deterministic rotating key + clamped expiry yield a byte-identical proof).
    ///
    /// A suspended iOS app can't run timers, so the wake is advisory: the guarantee is that every trigger
    /// (`willEnterForeground`, config sync, init, purchase, `Transaction.updates`) re-runs this.
    func reconcileProofRenewal() async {
        proofRenewalWakeTask?.cancel()
        proofRenewalWakeTask = nil

        guard dependencies[singleton: .appContext].isMainApp else { return }

        let nowMs: UInt64 = await dependencies.networkOffsetTimestampMs()
        let nowSeconds: Int64 = Int64(nowMs / 1000)
        let now: TimeInterval = TimeInterval(nowSeconds)

        let target: Int64 = dependencies.mutate(cache: .libSession) {
            $0.proRenewalTargetTimestampSeconds(nowUnixTimestampSeconds: nowSeconds)
        }

        /// DORMANT: nothing entitled and no pending purchase. Reset backoff; only a TRIGGER re-enters.
        guard target != 0 else { darkAttempt = 0; return }

        /// Not yet due → arm exactly one wake at the target and reset the dark backoff.
        if target > nowSeconds {
            darkAttempt = 0
            armProofRenewalWake(afterSeconds: TimeInterval(target - nowSeconds))
            return
        }

        /// Due. Covered (a currently-valid proof in hand — preemptive) spaces at a flat 60s; dark (no /
        /// expired proof — renewal-after-offline or prepaid acquisition) uses a linear backoff, bounding an
        /// abandoned purchase to ~15-min spacing. Covered resets the dark backoff (§2).
        let haveValidProof: Bool = currentUserProofIsValid(atTimestampMs: nowMs)
        if haveValidProof { darkAttempt = 0 }
        let interval: TimeInterval = (haveValidProof ? 60 : TimeInterval(min(15 * darkAttempt, 900)))

        /// Spacing / best-effort single-flight / lost-completion recovery: if a request started too recently,
        /// just (re)arm the wake for when the interval elapses and bail.
        if (now - lastProofRequestAt) < interval {
            armProofRenewalWake(afterSeconds: ((lastProofRequestAt + interval) - now))
            return
        }

        lastProofRequestAt = now
        if !haveValidProof { darkAttempt += 1 }

        /// Arm the next wake now (it also re-checks a lost/frozen completion), then fire the generate.
        let nextInterval: TimeInterval = (haveValidProof ? 60 : TimeInterval(min(15 * darkAttempt, 900)))
        armProofRenewalWake(afterSeconds: nextInterval)
        startProofGeneration(nowUnixTimestampSeconds: nowSeconds)
    }

    /// The advisory in-foreground wake. Unreliable across suspension (fine — a trigger re-runs reconcile);
    /// reliable while foregrounded, which is where a send can happen.
    private func armProofRenewalWake(afterSeconds delay: TimeInterval) {
        /// Round up to whole seconds and use the integer `.seconds` overload (the `Double` one is iOS 16+).
        let delaySeconds: Int = Int(max(0, delay).rounded(.up))
        proofRenewalWakeTask?.cancel()
        proofRenewalWakeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delaySeconds)) }
            catch { return }
            await self?.reconcileProofRenewal()
        }
    }

    private enum ProofGenerationOutcome {
        case response(Network.SessionPro.GenerateProProofResponse, rotatingKeyPair: KeyPair)
        case transient
    }

    /// Fire a `generate_pro_proof` (async), applying the outcome via `onProofComplete`. Not guarded against
    /// overlap (§1.9); a superseding call cancels the prior task best-effort.
    private func startProofGeneration(nowUnixTimestampSeconds: Int64) {
        proofGenerationTask?.cancel()
        proofGenerationTask = Task { [weak self] in
            guard let self else { return }

            let outcome: ProofGenerationOutcome = await self.performProofGeneration(
                nowUnixTimestampSeconds: nowUnixTimestampSeconds
            )
            await self.onProofComplete(outcome)
        }
    }

    private func performProofGeneration(nowUnixTimestampSeconds: Int64) async -> ProofGenerationOutcome {
        do {
            /// Preserve the network wait (rather than fail-fast → dark backoff) so a connectivity outage
            /// recovers promptly when the network returns, instead of waiting out the backed-off interval —
            /// there is no "network reachable" trigger in the reconcile event set.
            try await dependencies.ensureNetworkConnection(onWillStartWaiting: {
                Log.info(.sessionPro, "Waiting for network to connect before renewing the Pro proof.")
            })

            let rotatingKeyPair: KeyPair = try dependencies[singleton: .crypto]
                .tryGenerate(.sessionProRotatingKeyPair(nowUnixTimestampSeconds: nowUnixTimestampSeconds))
            let request = try Network.SessionPro.generateProProof(
                masterKeyPair: try dependencies[singleton: .crypto].tryGenerate(.sessionProMasterKeyPair()),
                rotatingKeyPair: rotatingKeyPair,
                using: dependencies
            )
            let response: Network.SessionPro.GenerateProProofResponse = try await request.send(using: dependencies)

            return .response(response, rotatingKeyPair: rotatingKeyPair)
        }
        catch {
            Log.error(.sessionPro, "Pro proof generation request failed (transient): \(error)")
            return .transient
        }
    }

    /// Apply a `generate_pro_proof` outcome to config (Rev 2 §4). A stale response must never reduce
    /// coverage — the guards read *live* config inside the write. Ends by reconciling again.
    private func onProofComplete(_ outcome: ProofGenerationOutcome) async {
        switch outcome {
            case .transient: break   /// nothing to write; the reconcile below re-arms the (backed-off) retry

            case .response(let response, let rotatingKeyPair):
                switch response.outcome {
                    case .success:
                        await applyProofSuccess(response, rotatingKeyPair: rotatingKeyPair)

                    /// Lapsed / no subscription → clear (proof `s` AND access-expiry `E`), but only if we
                    /// don't currently hold a valid proof (never let a stale failure wipe a fresh proof
                    /// another device just landed). Both outcomes mean "not entitled", so `E` must not be
                    /// left future — clearing it (rather than re-setting a past value) is spin-safe and
                    /// `get_pro_status` supplies the display horizon anyway.
                    case .subscriptionExpired, .notSubscribed:
                        await applyProofClear()

                    /// Revocation from a proof response is terminal: clear regardless of validity, no `E`
                    /// write, off the transient/backoff path.
                    case .revoked:
                        await applyProofRevoked()

                    /// Transient / unrecognised → nothing (opaque-value discipline: fail closed non-destructively).
                    case .transient:
                        break
                }
        }

        await reconcileProofRenewal()
    }

    /// success: monotonic upgrade of the proof (replace iff it extends coverage) + `E` co-write, all inside
    /// one atomic mutation so the current-expiry read can't race the write.
    private func applyProofSuccess(
        _ response: Network.SessionPro.GenerateProProofResponse,
        rotatingKeyPair: KeyPair
    ) async {
        try? await dependencies[singleton: .storage].write { [dependencies] db in
            try dependencies.mutate(cache: .libSession) { cache in
                try cache.performAndPushChange(db, for: .userProfile) { _ in
                    let currentExpiry: UInt64 = (cache.proConfig?.proProof.expiryUnixTimestampSeconds ?? 0)

                    /// Monotonic merge: ties (byte-identical same-period proofs) are no-ops → every device
                    /// converges on the longest-lived proof with no churn. Handles racing another client and
                    /// racing ourselves uniformly.
                    if response.proof.expiryUnixTimestampSeconds > currentExpiry {
                        cache.updateProConfig(
                            proConfig: SessionPro.ProConfig(
                                rotatingPrivateKey: rotatingKeyPair.secretKey,
                                proProof: response.proof
                            )
                        )
                    }

                    /// `E` is written NOT gated by the proof guard (§4 H4): a mid-period horizon extension
                    /// keeps the same clamped proof expiry but a later `account_expiry`. It's advisory/soft.
                    if response.accountExpiryTimestampSeconds > 0 {
                        cache.updateProAccessExpiryTimestampSeconds(response.accountExpiryTimestampSeconds)
                    }
                }
            }
        }

        /// Re-project the (now-updated) config into state — proof, rotating key, status, `E` all re-derive
        /// consistently (and if the winning proof was an existing longer one, the rotating key matches it).
        await updateWithLatestFromUserConfig()
        try? await Profile.updateLocal(proFeatures: syncState.state.profileFeatures, using: dependencies)
    }

    /// subscription_expired / not_subscribed clear — downgrade-guarded: apply only if there is no currently
    /// valid (unexpired) proof, read inside the write.
    private func applyProofClear() async {
        let nowSeconds: Int64 = Int64(await dependencies.networkOffsetTimestampMs() / 1000)

        try? await dependencies[singleton: .storage].write { [dependencies] db in
            try dependencies.mutate(cache: .libSession) { cache in
                try cache.performAndPushChange(db, for: .userProfile) { _ in
                    /// Downgrade guard (read live config): never wipe a fresh, unexpired proof another device
                    /// just landed. `remove_pro_config` deliberately leaves `pro_prepaid` so a pending
                    /// purchase keeps polling (§7.3).
                    let hasUnexpiredProof: Bool = ((cache.proConfig?.proProof.expiryUnixTimestampSeconds ?? 0) > UInt64(max(0, nowSeconds)))
                    guard !hasUnexpiredProof else { return }

                    /// `remove_pro_config` clears ONLY the proof `s`. `E` does NOT self-age (unlike the proof
                    /// `I`/`R`), so a stale future `E` left here would make `pro_renewal_target` fire on every
                    /// eval and spin — clear it explicitly (`set_pro_access_expiry(nullopt)`, via `0`).
                    cache.removeProConfig()
                    cache.updateProAccessExpiryTimestampSeconds(0)
                }
            }
        }

        await updateWithLatestFromUserConfig()
    }

    /// `revoked` from a proof response is authoritative and terminal — clear regardless of validity. Clears
    /// both the proof `s` and the access-expiry `E`: `remove_pro_config` only clears `s`, and a stale future
    /// `E` would keep `pro_renewal_target` firing (spin), so clear it too (`set_pro_access_expiry(nullopt)`,
    /// via `0`). Mirrors the revocation-list path (§6.4).
    private func applyProofRevoked() async {
        try? await dependencies[singleton: .storage].write { [dependencies] db in
            try dependencies.mutate(cache: .libSession) { cache in
                try cache.performAndPushChange(db, for: .userProfile) { _ in
                    cache.removeProConfig()
                    cache.updateProAccessExpiryTimestampSeconds(0)
                }
            }
        }

        await updateWithLatestFromUserConfig()
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
        
        do {
            try await dependencies.ensureNetworkConnection(onWillStartWaiting: {
                Log.info(.sessionPro, "Waiting for network to connect.")
            })
            let request = try Network.SessionPro.getProStatus(
                masterKeyPair: try dependencies[singleton: .crypto].tryGenerate(.sessionProMasterKeyPair()),
                using: dependencies
            )
            let response: Network.SessionPro.GetProStatusResponse = try await request
                .send(using: dependencies)

            guard response.header.isSuccess else {
                let diagnostic: String = (response.header.error ?? response.header.errorCode ?? "unknown error")
                Log.error(.sessionPro, "Failed to retrieve pro status due to error(s): \(diagnostic)")

                updatedState = oldState.with(
                    loadingState: .set(to: .error),
                    using: dependencies
                )

                syncState.update(state: .set(to: updatedState))
                await self.stateStream.send(updatedState)
                throw SessionProError.getProStatusFailed(response.header.userFacingMessage)
            }
            updatedState = oldState.with(
                status: .set(to: response.status),
                autoRenewing: .set(to: response.autoRenewing),
                accessExpiryTimestampSeconds: .set(to: response.expiryTimestampSeconds),
                latestPaymentItem: .set(to: response.latestPaymentItem),
                using: dependencies
            )
            
            if updatedState.accessExpiryTimestampSeconds != oldState.accessExpiryTimestampSeconds {
                dependencies[defaults: .standard, key: .hasShownProExpiringCTA] = false
            }
            
            switch (oldState.status, updatedState.status) {
                case (.expired, .active):
                    dependencies[defaults: .standard, key: .hasShownProExpiredCTA] = false
                default: break
            }
            
            syncState.update(state: .set(to: updatedState))
            await self.stateStream.send(updatedState)
            oldState = updatedState

            /// `get_pro_status` is authoritative for the account paid-through end, so mirror `expiry_ts` into
            /// config `E` (`set_pro_access_expiry`) unconditionally on every success. This is the crux that
            /// lets `pro_renewal_target` fire for a server-side voucher / recovered subscription (account
            /// active but with no local proof yet) — without it, `E` in config would stay absent and a proof
            /// would never be fetched. libsession clears `E` when handed `<= 0` (the never/expired
            /// `expiry_ts`) and only dirties the config on a real change, so the unconditional write is safe.
            try? await dependencies[singleton: .storage].write { [dependencies] db in
                try dependencies.mutate(cache: .libSession) { cache in
                    try cache.performAndPushChange(db, for: .userProfile) { _ in
                        cache.updateProAccessExpiryTimestampSeconds(response.expiryTimestampSeconds)
                    }
                }
            }

            /// `get_pro_status` is DISPLAY-ONLY for the PROOF (Rev 2 §1.3): it refreshes auto-renew / grace /
            /// refund / access-expiry fields but does NOT mint or clear the proof. The proof lifecycle — generate on
            /// due, and the §4 clears on `subscription_expired` / `not_subscribed` / `revoked` — is owned
            /// entirely by the reconcile loop's `generate_pro_proof` path, so we just kick a reconcile here
            /// (a status change may make a renewal / acquisition due).

            updatedState = oldState.with(
                loadingState: .set(to: .success),
                using: dependencies
            )

            syncState.update(state: .set(to: updatedState))
            await self.stateStream.send(updatedState)
            oldState = updatedState

            startStoreKitEntitlementsObservations()
            await entitlementsObservingTask?.value

            await reconcileProofRenewal()
        } catch {
            Log.error(.sessionPro, "Failed to retrieve pro status due to error(s): \(error)")
            
            updatedState = oldState.with(
                loadingState: .set(to: .error),
                using: dependencies
            )
            
            syncState.update(state: .set(to: updatedState))
            await self.stateStream.send(updatedState)
            throw SessionProError.getProStatusFailed("\(error)")
        }
    }
    
    @MainActor public func cancelPro(scene: UIWindowScene) async throws {
        do {
            try await AppStore.showManageSubscriptions(in: scene)
            
            try await refreshProState()
        }
        catch {
            throw SessionProError.failedToShowStoreKitUI("Manage Subscriptions")
        }
    }
    
    @MainActor public func requestRefund(scene: UIWindowScene) async throws {
        let currentState: SessionPro.State = await stateStream.getCurrent()

        guard let latestPaymentItem: Network.SessionPro.PaymentItem = currentState.latestPaymentItem else {
            throw SessionProError.noLatestPaymentItem
        }

        /// User has already requested a refund — this is config-synced state now, not a per-payment field.
        guard currentState.refundRequestedTimestampSeconds == 0 else {
            throw SessionProError.refundAlreadyRequestedForLatestPayment
        }

        /// Only Apple supports refunding via this mechanism, so no point continuing without an Apple transaction
        guard latestPaymentItem.appleTransactionId != nil else {
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
        
        /// Refund state is config-synced now (there's no `set_payment_refund_requested` backend call): record
        /// the request in the user config via `user_profile_set_refund_requested`, which propagates to the
        /// user's other devices. The network clock is milliseconds; refund-requested time is whole seconds
        /// like the rest of Pro.
        let refundRequestedTimestampSeconds: UInt64 = await syncState.dependencies.networkOffsetTimestampMs() / 1000
        try await syncState.dependencies[singleton: .storage].write { [dependencies = syncState.dependencies] db in
            try dependencies.mutate(cache: .libSession) { cache in
                try cache.performAndPushChange(db, for: .userProfile) { _ in
                    cache.updateRefundRequested(refundRequestedTimestampSeconds)
                }
            }
        }

        /// Re-read from the config so the (now config-backed) refund-pending flag lands in our state.
        await updateWithLatestFromUserConfig()
    }
        
    // MARK: - Internal Functions

    // MARK: -- Pro Invalidation Scheduling

    /// Schedule a task to emit profile events at the next instant a contact's pro state goes stale
    ///
    /// `profileFeatures(for:)` derives its result from the *current time* - a proof expiring, or a revocation reaching its
    /// `effective_at` - but that result is snapshotted into the view models when they're built and nothing recomputes it when
    /// the instant actually passes. Without this a contact's pro badge (and animated display picture) can persist until some
    /// unrelated change happens to trigger a rebuild.
    ///
    /// We emit the existing per-profile events, which the screens showing a badge already observe, so no screen needs to opt in.
    /// The profile rows themselves are unchanged (their stored expiry is still whatever it always was) - it's the passage of
    /// time that changed the derived value, so rebuilding the view model is the entire fix.
    private func scheduleNextProInvalidation() async {
        proInvalidationTask?.cancel()
        proInvalidationTask = nil

        /// Emit anything that lapsed since we last looked before arming the next wake-up - after the app has been suspended past
        /// an instant, the window between the last check and now can contain lapses we never emitted
        await catchUpProInvalidation()

        proInvalidationTask = Task { [weak self] in
            /// **Note:** This loops rather than re-entering `scheduleNextProInvalidation()` after each wake-up. Doing the latter would
            /// have the fired task cancel *itself* as its first action, leaving the remaining `await`s running under cancellation - the
            /// following database read could then bail out and silently end the chain.
            while !Task.isCancelled {
                guard
                    let self,
                    let delaySeconds: Int = await self.nextProInvalidationDelay()
                else { return }     /// Nothing upcoming - a reschedule trigger will restart us if that changes

                do { try await Task.sleep(for: .seconds(delaySeconds)) }
                catch { return }    /// Cancelled - whoever cancelled us is responsible for rescheduling

                guard !Task.isCancelled else { return }

                await self.catchUpProInvalidation()
            }
        }
    }

    /// Emit for everything which lapsed in `(lastProInvalidationCheck, now]` and advance the marker
    ///
    /// **Note:** Nothing is emitted the first time through (the marker is still `0`) which is intentional - at startup every view model
    /// is built fresh and evaluates `profileFeatures(for:)` against the current time anyway, so re-emitting for profiles which lapsed
    /// while the app was closed would be pure noise.
    private func catchUpProInvalidation() async {
        let now: TimeInterval = dependencies.dateNow.timeIntervalSince1970

        if lastProInvalidationCheck > 0 {
            await emitProInvalidationEvents(since: lastProInvalidationCheck, until: now)
        }

        lastProInvalidationCheck = now
    }

    /// How long to wait before the next instant, or `nil` if there's nothing upcoming
    private func nextProInvalidationDelay() async -> Int? {
        let now: TimeInterval = dependencies.dateNow.timeIntervalSince1970

        guard let nextInstant: TimeInterval = await nextProInvalidationInstant(after: now) else { return nil }

        /// Round up to at least one whole second - waking even fractionally early would leave the instant still in the future, so the
        /// window query would match nothing and we'd immediately re-arm for the same instant and spin
        return max(1, Int((nextInstant - now).rounded(.up)))
    }

    /// The earliest upcoming instant at which some profile's derived pro state will change
    ///
    /// **Note:** Only instants strictly after `now` are considered, which is what stops an already-passed instant from being
    /// rescheduled forever (a lapsed profile keeps its stored expiry, so it would otherwise match on every pass)
    private func nextProInvalidationInstant(after now: TimeInterval) async -> TimeInterval? {
        /// The revocation list is already held in memory so this side costs nothing
        let nextEffective: TimeInterval? = syncState.revocationList
            .map { TimeInterval($0.effectiveTimestampSeconds) }
            .filter { $0 > now }
            .min()

        /// Profiles need a query - there's no global in-memory profile cache to consult (`ConversationDataCache` is a
        /// per-observation snapshot). This runs on reschedule rather than per-frame, so a `MIN()` scan is fine.
        let nextExpiry: TimeInterval? = (try? await dependencies[singleton: .storage].read { db in
            try Profile.nextProExpiry(db, after: UInt64(max(0, now)))
        })
        .map { TimeInterval($0) }

        return [nextEffective, nextExpiry].compactMap { $0 }.min()
    }

    /// Emit a profile event for every profile whose pro state went stale within `(since, until]`
    ///
    /// A window (rather than "everything that has lapsed") keeps this to one emission per lapse - otherwise every historically
    /// expired profile would be re-emitted on every wake-up
    private func emitProInvalidationEvents(since: TimeInterval, until: TimeInterval) async {
        guard until > since else { return }

        /// Revocation items reference a proof by tag, so we match profiles on the tag rather than the profile id
        let newlyEffectiveTags: Set<String> = Set(
            syncState.revocationList
                .filter { item in
                    let effective: TimeInterval = TimeInterval(item.effectiveTimestampSeconds)

                    return (effective > since && effective <= until)
                }
                .map { $0.revocationTag.toHexString() }
        )
        let affectedProfiles: [Profile]? = try? await dependencies[singleton: .storage].read { db in
            try Profile.withProStateInvalidated(
                db,
                since: UInt64(max(0, since)),
                until: UInt64(max(0, until)),
                revocationTagsHex: newlyEffectiveTags
            )
        }

        guard let affectedProfiles: [Profile], !affectedProfiles.isEmpty else { return }

        /// Send the profile's **stored** values - the row genuinely hasn't changed, and the direct-cache-update path writes these
        /// straight into the cached profile, so anything else here would corrupt it. The events exist to force the requery which
        /// re-derives `profileFeatures(for:)` against the current time.
        await dependencies.notify(
            events: affectedProfiles.map { profile in
                ObservedEvent(
                    key: .profile(profile.id),
                    value: ProfileEvent(
                        id: profile.id,
                        change: .proStatus(
                            isPro: Profile.ProState(
                                profileFeatures: profile.proFeatures,
                                expiryUnixTimestampSeconds: profile.proExpiryUnixTimestampSeconds,
                                revocationTagHex: profile.proRevocationTagHex
                            ).isPro,
                            profileFeatures: profile.proFeatures,
                            expiryUnixTimestampSeconds: profile.proExpiryUnixTimestampSeconds,
                            revocationTagHex: profile.proRevocationTagHex
                        )
                    )
                )
            }
        )

        Log.info(.sessionPro, "Invalidated pro state for \(affectedProfiles.count) profile(s).")
    }

    /// Re-evaluate the invalidation schedule when the app returns to the foreground, or when any profile's pro status changes
    ///
    /// **Foreground:** iOS suspends the process, so a `Task.sleep` targeting an instant hours away will **not** fire on time across
    /// a background period - the app can resume well past the instant with a stale badge still on screen. Re-evaluating here emits
    /// anything that lapsed while we were suspended (the window in `emitProInvalidationEvents` covers it) and re-arms the timer.
    ///
    /// **Pro status change:** a newly received proof can expire *earlier* than whatever we're currently waiting on, and if nothing
    /// is scheduled yet (no known pro contacts) there'd be no wake-up to correct it at all.
    private func startProInvalidationRescheduleObservations() {
        appLifecycleObservingTask?.cancel()
        appLifecycleObservingTask = Task { [weak self, dependencies] in
            await withTaskGroup(of: Void.self) { group in
                let keys: [ObservableKey] = [
                    .appLifecycle(.willEnterForeground),
                    .anyProfileProStatusChanged
                ]

                for key in keys {
                    group.addTask {
                        let stream: AsyncStream<ObservedEvent> = await dependencies[singleton: .observationManager]
                            .observe(key)

                        for await _ in stream {
                            guard !Task.isCancelled else { return }

                            await self?.scheduleNextProInvalidation()

                            /// Returning to the foreground is also our robust proof-renewal trigger: re-run the
                            /// reconcile so a renewal target that elapsed while suspended is caught before the
                            /// user can send. (Badge rescheduling above handles other profiles; this handles
                            /// our own proof.) Gated to the lifecycle key so a contact's status change — the
                            /// other observed key — doesn't thrash the renewal task.
                            if key == .appLifecycle(.willEnterForeground) {
                                await self?.reconcileProofRenewal()
                            }
                        }
                    }
                }
            }
        }
    }

    private func startRevocationListTask() {
        revocationListTask = Task {
            do {
                try await dependencies.ensureNetworkConnection(onWillStartWaiting: {
                    Log.info(.sessionPro, "Waiting for network to connect before updating Pro revocation list.")
                })
                
                let revocationList: [RevocationItem] = try await dependencies[singleton: .storage].read { db in
                    db[.proRevocationList] ?? []
                }
                syncState.update(revocationList: .set(to: revocationList))
            } catch {
                Log.warn(.sessionPro, "Failed to load revocation list from db: \(error)")
            }
            
            while true {
                do {
                    let ticket: Int64 = try await Result(
                        catching: {
                            try await dependencies[singleton: .storage].read { db in
                                Int64(db[.proRevocationsTicket] ?? 0)
                            }
                        }
                    )
                    .mapError { SessionProError.getProRevocationsFailed("Could not retrieve ticket (\($0))") }
                    .get()
                    let request = try Network.SessionPro.getProRevocations(
                        ticket: ticket,
                        using: dependencies
                    )
                    let response: Network.SessionPro.GetProRevocationsResponse = try await request
                        .send(using: dependencies)
                    
                    guard response.header.isSuccess else {
                        let diagnostic: String = (response.header.error ?? response.header.errorCode ?? "unknown error")
                        Log.error(.sessionPro, "Failed to fetch pro revocations due to error(s): \(diagnostic)")
                        throw SessionProError.getProRevocationsFailed(response.header.userFacingMessage)
                    }

                    
                    try await dependencies[singleton: .storage].write { db in
                        db[.proRevocationsTicket] = Int(response.ticket)
                        db[.proRevocationList] = response.items
                    }
                    
                    syncState.update(revocationList: .set(to:response.items))

                    /// §6.4: the revocation-list path is authoritative — if the current user's OWN proof is
                    /// now revoked, clear the credential (regardless of expiry/validity). Otherwise a
                    /// revoked-but-unexpired proof would keep passing the expiry-only checks and get attached.
                    await clearOwnCredentialIfRevoked()

                    /// Send out a notification that the revocations list was updated, in case something wants to immediately respond
                    await dependencies.notify(
                        key: .proRevocationListUpdated,
                        value: response.items
                    )

                    /// The list we schedule against just changed, so the next `effective_at` may have moved
                    await scheduleNextProInvalidation()
                    
                    Log.info(.sessionPro, (response.ticket != ticket ? "Successfully updated revocation list to \(response.ticket)." : "Revocation list already up-to-date."))

                    /// Wait the server-recommended interval before polling again; libSession clamps
                    /// `retry_in`/`retain_for` to sane bounds in its revocations parser, so we use it as-is.
                    try? await Task.sleep(for: .seconds(Int(response.retryInSeconds)))
                }
                catch {
                    Log.warn(.sessionPro, "\(error), will retry in 10s.")
                    try? await Task.sleep(for: .seconds(10))
                    continue
                }
            }
        }
    }
    
    private func startStoreKitTransactionObservations() {
        transactionObservingTask?.cancel()
        transactionObservingTask = Task {
            for await result in Transaction.updates {
                do {
                    switch result {
                        case .verified(let transaction):
                            /// Redemption is implicit now — there's no add-payment call. A verified transaction
                            /// (a renewal, or a purchase completed on another device) just needs the entitlement
                            /// pulled through: mark the purchase in-flight, refresh the display state, and let the
                            /// reconcile loop request the proof (`refreshProState` also kicks a reconcile at its
                            /// end, and the dark path binds a payment the backend hasn't yet).
                            ///
                            /// Record the marker (durably dumped by the config write) BEFORE `finish()`, so a
                            /// crash in between lets StoreKit redeliver the transaction rather than losing it —
                            /// `finish()` only stops that redelivery, it doesn't affect the payment.
                            try await markPurchaseInFlight()
                            await transaction.finish()
                            try? await refreshProState()
                            await reconcileProofRenewal()

                        case .unverified(_, let error):
                            Log.error(.sessionPro, "Received an unverified transaction update: \(error)")
                    }
                    
                }
                catch {
                    Log.error(.sessionPro, "Failed to retrieve transaction from update: \(error)")
                }
            }
        }
    }
    
    private func startStoreKitEntitlementsObservations() {
        entitlementsObservingTask?.cancel()
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
    
    private func startStoreKitObservations() {
        startStoreKitTransactionObservations()
        startStoreKitEntitlementsObservations()
    }
    
    /// §6.4 self-revocation clear: if the current user's own proof's revocation tag is on the (now-updated)
    /// revocation list with an effective instant that has passed, remove the credential — authoritative,
    /// regardless of expiry. No-op when we hold no proof or it isn't revoked.
    private func clearOwnCredentialIfRevoked() async {
        let nowSeconds: TimeInterval = dependencies.dateNow.timeIntervalSince1970

        let ownProofRevocationTagHex: String? = dependencies.mutate(cache: .libSession) {
            $0.proConfig?.proProof.revocationTag.toHexString()
        }

        guard let ownProofRevocationTagHex: String = ownProofRevocationTagHex else { return }

        let isRevoked: Bool = syncState.revocationList.contains { item in
            TimeInterval(item.effectiveTimestampSeconds) <= nowSeconds &&
            item.revocationTag.toHexString() == ownProofRevocationTagHex
        }

        guard isRevoked else { return }

        Log.warn(.sessionPro, "Own Pro proof was revoked; clearing the credential.")
        try? await dependencies[singleton: .storage].write { [dependencies] db in
            try dependencies.mutate(cache: .libSession) { cache in
                try cache.performAndPushChange(db, for: .userProfile) { _ in
                    cache.removeProConfig()
                }
            }
        }

        await updateWithLatestFromUserConfig()
    }
}

// MARK: - SyncState

private final class SessionProManagerSyncState {
    private let lock: NSLock = NSLock()
    private let _dependencies: Dependencies
    private var _rotatingKeyPair: KeyPair? = nil
    private var _state: SessionPro.State = .invalid
    private var _revocationList: [RevocationItem] = []
    
    fileprivate var dependencies: Dependencies { lock.withLock { _dependencies } }
    fileprivate var rotatingKeyPair: KeyPair? { lock.withLock { _rotatingKeyPair } }
    fileprivate var state: SessionPro.State { lock.withLock { _state } }
    fileprivate var revocationList: [RevocationItem] { lock.withLock { _revocationList } }
    
    fileprivate init(using dependencies: Dependencies) {
        self._dependencies = dependencies
    }
    
    fileprivate func update(
        rotatingKeyPair: Update<KeyPair?> = .useExisting,
        state: Update<SessionPro.State> = .useExisting,
        revocationList: Update<[RevocationItem]> = .useExisting
    ) {
        lock.withLock {
            self._rotatingKeyPair = rotatingKeyPair.or(self._rotatingKeyPair)
            self._state = state.or(self._state)
            self._revocationList = revocationList.or(self._revocationList)
        }
    }
}

// MARK: - SessionProManagerType

public protocol SessionProManagerType: SessionProUIManagerType {
    nonisolated var characterLimit: Int { get }
    nonisolated var currentUserCurrentRotatingKeyPair: KeyPair? { get }
    nonisolated var currentUserCurrentProState: SessionPro.State { get }
    
    nonisolated var state: AsyncStream<SessionPro.State> { get }
    
    nonisolated func proProofIsActive(
        for proof: Network.SessionPro.ProProof?,
        atTimestampMs timestampMs: UInt64
    ) -> Bool
    nonisolated func messageFeatures(for message: String) -> SessionPro.FeaturesForMessage
    nonisolated func profileFeatures(for profile: Profile?) -> SessionPro.ProfileFeatures
    nonisolated func messageProFeatureList(_ features: SessionPro.MessageFeatures) -> SessionPro.MessageFeatures
    nonisolated func profileProFeatureList(_ features: SessionPro.ProfileFeatures) -> SessionPro.ProfileFeatures
    nonisolated func attachProInfoIfNeeded(message: Message) -> Message
    func sessionProExpiringCTAInfo() async -> (variant: ProCTAModal.Variant, paymentFlow: SessionProPaymentScreenContent.SessionProPlanPaymentFlow, planInfo: [SessionProPaymentScreenContent.SessionProPlanInfo])?
    
    // MARK: - State Management
    
    func updateWithLatestFromUserConfig() async
    
    func purchasePro(productId: String) async throws
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
    
    static let proAccessExpiryUpdated: ObservableKey = ObservableKey(
        "proAccessExpiryUpdated",
        .proAccessExpiryUpdated
    )
    
    static let proRevocationListUpdated: ObservableKey = ObservableKey(
        "proRevocationListUpdated",
        .proRevocationListUpdated
    )
}

// stringlint:ignore_contents
public extension GenericObservableKey {
    static let currentUserProState: GenericObservableKey = "currentUserProState"
    static let proAccessExpiryUpdated: GenericObservableKey = "proAccessExpiryUpdated"
    static let proRevocationListUpdated: GenericObservableKey = "proRevocationListUpdated"
}

// MARK: - Mocking

private extension SessionProManager {
    private func startProMockingObservations() {
        proMockingObservationTask = ObservationBuilder
            .initialValue(SessionPro.MockState(using: dependencies))
            .using(dependencies: dependencies)
            .query { previousState, _, _, dependencies in
                SessionPro.MockState(previousInfo: previousState.info, using: dependencies)
            }
            .assign { [weak self] state in
                Task.detached(priority: .userInitiated) {
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

