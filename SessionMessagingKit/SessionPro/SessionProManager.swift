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

    /// The `get_pro_status` refresh timings.
    ///
    /// **These are a deliberate cross-client contract, not iOS tuning knobs** — Android and desktop carry the same
    /// values under their own names, and the whole point of unifying the refresh design was that nobody tunes one
    /// platform in isolation. Change them together or not at all.
    public enum StatusRefresh {
        /// Minimum gap between routine `get_pro_status` fetches. **Drop-on-fresh, never re-arm:** a re-arming floor
        /// turns every routine trigger into a self-sustaining once-a-minute poll, which during grace (when `E` is
        /// static) is pure noise. The *proof* loop is deliberately the opposite — it re-arms rather than skips,
        /// because a throttled proof acquisition still has to eventually happen. Don't unify the two.
        ///
        /// ⚠️ **A scheduled wake depends on this value not being crossed.** The `user_expiry` wakes fire at
        /// `E + 30s` and `(E + G) + 30s`, so they are `G` apart, and **both go through the floored fetch path**
        /// (not `immediate`). Whenever `G < floorSeconds` the second wake's fetch is therefore dropped by the
        /// floor — silently, and looking exactly as though the wake had never been scheduled.
        ///
        /// In production `G` is ~1 hour, so this never bites. It bites on a **compressed testing backend**: the
        /// Google testing provider sets the grace period to ~10 seconds, and the backend scales its whole test
        /// clock (clamp, renewal lead, grid) while this fixed client-side floor doesn't participate in that
        /// compression. Any client interval shorter than the compressed equivalent has the same property — the
        /// second wake is just where the mismatch first became visible.
        ///
        /// **Deliberately not solved here.** The sanctioned escape hatch is an env-var override of this floor,
        /// owned by the Pro UI-test work; do not add one to the client, make the wake `immediate`, or widen the
        /// wake's guard to compensate. Raising or removing this constant likewise needs the wakes re-checked.
        public static let floorSeconds: UInt64 = 60

        /// Minimum gap between **startup-gate** fetches. Cold starts are frequent on mobile, so the gate needs its
        /// own rate limit; this also doubles as the backstop that lets a stale `auto_renewing`/`E` self-correct
        /// within a day.
        public static let startupMinIntervalSeconds: UInt64 = 24 * 60 * 60

        /// How far before `E` a non-renewing subscription counts as "expiring" — the startup gate's CTA window, and
        /// the same 7 days the Expiring CTA itself uses.
        public static let expiringCTAWindowSeconds: UInt64 = 7 * 24 * 60 * 60

        /// How long after `E` an expired subscription still warrants the Expired CTA.
        public static let expiredCTAWindowSeconds: UInt64 = 30 * 24 * 60 * 60

        /// Slack added to `E` for the single `user_expiry` wake. Firing at exactly `E` would routinely re-read the
        /// same un-renewed period a moment before the backend rolls it over, spending a fetch to learn nothing.
        public static let userExpiryWakeSlackSeconds: UInt64 = 30

        /// The post-purchase chase (trigger #7). Floor-exempt, so these two *are* its bound: the window is measured
        /// from the FIRST request, and the gap is applied after each attempt SETTLES rather than as a fixed tick, so a
        /// slow onion request can never overlap itself.
        public static let postPurchasePollWindowSeconds: Int64 = 120
        public static let postPurchasePollGapSeconds: Int = 5
    }

    /// The proof-acquisition floor (Loop 1).
    ///
    /// **Deliberately re-arms rather than drops**, which is the opposite of the status floor above: a throttled proof
    /// acquisition is load-bearing and must still eventually happen, whereas a dropped status refresh is display-only
    /// and backstopped by six other triggers. Don't unify the two — the asymmetry is the design.
    public enum ProofAcquisition {
        /// Spacing while COVERED — a currently-valid proof is in hand, so renewal is preemptive and can be leisurely.
        public static let coveredIntervalSeconds: TimeInterval = 60

        /// Spacing while DARK — no proof, or an expired one (renewal-after-offline, or a prepaid acquisition). Linear
        /// in the attempt count so an abandoned purchase decays to the cap rather than polling forever at 15s.
        public static let darkIntervalStepSeconds: Int = 15
        public static let darkIntervalCapSeconds: Int = 900
    }
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

    /// The `user_expiry` status wakes (trigger #6) — **two instants, so a collection**.
    ///
    /// `userExpiryWakeTasks` holds one advisory in-foreground wake per scheduled instant;
    /// `firedUserExpiryWakeInstants` records which have already fired, which is what makes each fire once per
    /// period rather than repeat. Both are ephemeral — re-derived from config on every evaluation, reset on
    /// process death.
    ///
    /// **This must stay a collection.** A single handle, cancelled once while scheduling two timers, silently
    /// orphans the first and leaks a timer every renewal period — and it would not show up in a test asserting
    /// the wakes fire at the right times, because they both still do.
    private var userExpiryWakeTasks: [Task<Void, Never>] = []
    private var firedUserExpiryWakeInstants: Set<UInt64> = []

    /// Config-change detection state for the status trigger, tracked here rather than read back out of
    /// `SessionPro.State`.
    ///
    /// 🔴 **These must not be display state.** `E` used to be diffed as two `SessionPro.State` snapshots, which tied
    /// "did config change" to "what does the UI currently show" — so anything that made the displayed expiry
    /// response-sourced rather than config-sourced would silently stop the config trigger firing at all, taking the
    /// remote-merge path with it. Nothing about the display can reach this now.
    ///
    /// `hasProjectedUserConfig` distinguishes the first projection of a process (not a change) from a genuine one.
    private var lastKnownAccessExpirySeconds: UInt64 = 0
    private var lastKnownPrepaidTimestampSeconds: UInt64 = 0
    private var hasProjectedUserConfig: Bool = false

    /// The instant up to which we have already emitted "this profile's pro state just went stale" events
    ///
    /// Used as the lower bound of the window in `emitProInvalidationEvents(since:until:)` so that each lapse is emitted exactly
    /// once, and so a lapse that happened while the app was suspended is still caught on the next evaluation
    private var lastProInvalidationCheck: TimeInterval = 0

    private var isRefreshingState: Bool = false

    /// Whether a `get_pro_status` has been attempted at all in this process. Exempts the first attempt from the
    /// (persisted) status floor — see `statusFloorPermitsFetch`.
    ///
    /// **It is load-bearing for two independent reasons, so removing it needs both answered.** Beyond the
    /// spinner case below, the floor is the *other* thing in this file that can decline to start a fetch — and
    /// without this exemption a fresh process whose floor is still armed from the previous one cannot fetch,
    /// which is the same dead-end as gating a refresh on `LoadingState.loading` (see that type's note).
    ///
    /// **Sole consumer is that exemption.** Deleting this and letting the persisted timestamp govern the first attempt
    /// too *was tried*, and it ships a **permanent spinner**: relaunch within 60s of a previous fetch and the floor
    /// drops the startup fetch, leaving `loadingState` on its initial `.loading` with nothing to resolve it — and both
    /// the Pro screen and the CTA gate on a confirmed fetch. So it is removable only once a fresh process can resolve
    /// its load state without a network round-trip; if that ever becomes true, delete this then and not before.
    private var hasAttemptedStatusFetch: Bool = false
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
            
            /// Kick off a refresh so we know we have the latest state (if it's the main app), but only when
            /// the config we just projected says it's warranted — see `startupStatusFetchIsNeeded`.
            if dependencies[singleton: .appContext].isMainApp, await self?.startupStatusFetchIsNeeded() == true {
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
        userExpiryWakeTasks.forEach { $0.cancel() }
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
            prepaidTimestampSeconds: UInt64,
            autoRenewing: Bool,
            gracePeriodSeconds: UInt64
        )
        let proInfo: ProInfo = dependencies.mutate(cache: .libSession) {
            (
                $0.proConfig,
                $0.profile,
                $0.proAccessExpiryTimestampSeconds,
                $0.refundRequestedTimestampSeconds,
                $0.proPrepaidTimestampSeconds,
                $0.proAutoRenewing,
                $0.proGracePeriodSeconds
            )
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

        /// 🔴 **`E`, `G` and `A` are deliberately NOT projected here — the display copies of those three are owned by
        /// whichever response last spoke.** Both `get_pro_status` and `generate_pro_proof` return all three, and only
        /// a response carries the rest of the picture that has to agree with them (`latest_payment` — provider, plan,
        /// refund window — has no config representation at all), so sourcing one field from config would leave the
        /// screen showing a mix of two different moments.
        ///
        /// Config keeps the same three for two other jobs, which is why they still exist there: it is the
        /// **fetch trigger** (`expiryChanged` below) and the **cross-device carrier**. This is the whole split —
        /// *config answers "should I fetch"; a response answers "what do I show"*.
        ///
        /// **So every proof outcome writes these itself** — `applyProofSuccess`, `applyProofClear` and
        /// `applyProofRevoked` — because a purchase learns its new expiry from the *proof* response, and until this
        /// method stopped projecting them, that write was what carried it to the display. Adding a fourth writer of
        /// config `E`/`G`/`A` without a matching display write would silently leave the screen a period behind.
        let updatedState: SessionPro.State = oldState.with(
            status: .set(to: proStatus),
            proof: .set(to: proInfo.proConfig?.proProof),
            profileFeatures: .set(to: proInfo.profile.proFeatures),
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

        /// A change to `E` or the prepaid marker `I` generally means another device did something that should refresh
        /// the pro state.
        ///
        /// **`I` is included, not just `E`.** A purchase started on another device sets only `I` — with `E` unchanged
        /// until the entitlement actually lands — so watching `E` alone leaves that case with no status refresh.
        ///
        /// Both diffed against the **config** values last seen, never against display state — see the note on
        /// `lastKnownAccessExpirySeconds`. `G` is deliberately not watched: a grace change *is* the information rather
        /// than a signal that the server moved, so fetching to confirm what we were just told is a wasted round trip.
        /// Same reason `A` isn't watched.
        let expiryChanged: Bool = (proInfo.accessExpiryTimestampSeconds != lastKnownAccessExpirySeconds)
        let prepaidChanged: Bool = (proInfo.prepaidTimestampSeconds != lastKnownPrepaidTimestampSeconds)
        let isFirstProjection: Bool = !hasProjectedUserConfig
        lastKnownAccessExpirySeconds = proInfo.accessExpiryTimestampSeconds
        lastKnownPrepaidTimestampSeconds = proInfo.prepaidTimestampSeconds
        hasProjectedUserConfig = true

        /// The first pass of a process is a *projection* of config we already had, not a config *change*. Treating it
        /// as one would fire this refresh on every cold launch — before, and regardless of, the startup gate — which
        /// would walk straight past the gate and leave the startup hammering the gate exists to remove.
        if !isFirstProjection, (expiryChanged || prepaidChanged) {
            try? await refreshProState()
        }

        if expiryChanged {
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

        /// `E` may have just moved (our own write, or another device's config push), so re-evaluate the
        /// `user_expiry` wake against it.
        await evaluateUserExpiryStatusWake()
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

            /// The baseline "a new period landed" is measured against.
            ///
            /// 🔴 **Optional, and deliberately not `?? 0`.** Display state carries no account expiry until a
            /// response has supplied one, and this poll starts before either the proof response or the first
            /// `get_pro_status` has landed (the proof generation is an unawaited task, so `purchasePro` returns
            /// ahead of it). Reading "we don't know yet" as `0` makes the first response look like an advance from
            /// nothing — including when it is carrying the *pre-purchase* expiry because the payment hasn't
            /// registered yet — which ends the poll on its first attempt at exactly the moment it exists to keep
            /// chasing. With no baseline, the first response supplies one instead of being compared against a
            /// value we never had.
            var expiryBefore: UInt64? = await self.stateStream.getCurrent().accessExpiryTimestampSeconds
            let startSeconds: Int64 = Int64(await self.dependencies.networkOffsetTimestampMs() / 1000)
            let windowSeconds: Int64 = SessionPro.StatusRefresh.postPurchasePollWindowSeconds

            while true {
                if Task.isCancelled { return }

                /// Fire and AWAIT settle (fresh response, or failure/timeout — `try?` swallows the throw).
                ///
                /// `immediate` because this poll is one of the two floor-exempt bounded chases: its whole job is to
                /// re-ask faster than the routine floor allows, and it carries its own cadence and termination.
                try? await self.refreshProState(immediate: true)

                let expiryNow: UInt64? = await self.stateStream.getCurrent().accessExpiryTimestampSeconds

                if let baseline: UInt64 = expiryBefore {
                    if let expiryNow: UInt64 = expiryNow, expiryNow > baseline { return }   /// new period landed
                }
                else {
                    expiryBefore = expiryNow   /// no baseline to compare against — this response becomes it
                }

                /// Stop kicking off new requests once ≥2 min since the first fire (the just-completed one
                /// was allowed to finish; we simply don't start another).
                let nowSeconds: Int64 = Int64(await self.dependencies.networkOffsetTimestampMs() / 1000)
                if (nowSeconds - startSeconds) >= windowSeconds { return }

                /// 5s gap BETWEEN completed attempts (not a fixed tick).
                do { try await Task.sleep(for: .seconds(SessionPro.StatusRefresh.postPurchasePollGapSeconds)) }
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

    // MARK: -- User Expiry Status Wake (trigger #6)

    /// The `user_expiry` wakes: a `get_pro_status` refetch shortly after the renewal falls due, and a second
    /// shortly after coverage ends. Each fires once per period.
    ///
    /// This is the gap they exist to close. The proof is clamped to expire well short of the account horizon,
    /// so the proof reconcile's wake is otherwise the *next* thing that goes to the network — and the renewal
    /// lands somewhere in between. Without these, an account whose renewal was overdue showed a stale "active"
    /// for that whole interval, and a "renewal pending / overdue" display cannot be driven off anything we
    /// haven't re-read. The while-open grace poll only covers the case where the Pro screen happens to be open.
    ///
    /// The slack (see `StatusRefresh.userExpiryWakeSlackSeconds`) is for clock skew against the backend: firing
    /// at exactly the instant would routinely re-read the same period a moment before it rolls over.
    ///
    /// **Once per instant, not repeating.** `firedUserExpiryWakeInstants` records what has fired, so a refetch
    /// that changes nothing is not retried from here — the ongoing chase belongs to the while-open grace poll
    /// and the other triggers. A refetch that *does* move `E` yields new instants, and since those are in the
    /// future they cannot spin.
    ///
    /// The wakes are advisory, like the proof one: iOS suspends the process, so a `Task.sleep` spanning either
    /// instant will not fire on time. `willEnterForeground` re-enters here, and the past-due branch below is
    /// what catches up a crossing missed while suspended.
    private func evaluateUserExpiryStatusWake() async {
        userExpiryWakeTasks.forEach { $0.cancel() }
        userExpiryWakeTasks = []

        guard dependencies[singleton: .appContext].isMainApp else { return }

        /// Read from config rather than from `state`: config is the authoritative cross-device value and is what
        /// the startup gate and the proof reconcile both key off, so all three agree on one clock. One mutation,
        /// since `E` and `G` are only comparable as the pair that arrived together.
        let (expirySeconds, graceSeconds): (UInt64, UInt64) = dependencies.mutate(cache: .libSession) {
            ($0.proAccessExpiryTimestampSeconds, $0.proGracePeriodSeconds)
        }

        /// Nothing known (never Pro, or cleared by a not-entitled proof outcome) — nothing to wake for. Forget
        /// what we fired for, so a later subscription landing on the *same* instants isn't swallowed.
        guard expirySeconds > 0 else {
            firedUserExpiryWakeInstants = []
            return
        }

        /// Clamped, not trapping — see `startupStatusFetchIsCTAWorthy`. With `G == 0` this yields `E`, so the two
        /// instants coincide and a single wake is scheduled, which is the right answer when there is no grace
        /// window to ask about separately.
        let coverageEndSeconds: UInt64 = (
            expirySeconds > (UInt64.max - graceSeconds) ? UInt64.max : expirySeconds + graceSeconds
        )
        let slackSeconds: UInt64 = SessionPro.StatusRefresh.userExpiryWakeSlackSeconds
        let nowSeconds: UInt64 = (await dependencies.networkOffsetTimestampMs() / 1000)

        /// **Two instants, and they answer different questions.**
        ///
        /// - `E + 30s` — the renewal has just fallen due: did the charge succeed or fail?
        /// - `(E + G) + 30s` — coverage has just ended: did grace run out without a recovery?
        ///
        /// The second is armed **only when the two instants don't coincide**. That is the condition itself,
        /// not a proxy for it: when they land on the same second there is one thing to ask, so there is one
        /// wake. Deliberately *not* phrased as "when a grace period exists" — that invites replacing the
        /// comparison with a `graceSeconds > 0` test, which is a different predicate that happens to agree
        /// today. (It's the non-auto-renewing accounts that coincide, since the backend sends `G = 0` there.)
        ///
        /// The second is not redundant with the proof loop landing near `E`: that chain reaches a status
        /// refresh only via the config-change trigger, which fires on `E` *changing*. A renewal that **failed**
        /// leaves `E` untouched, so nothing would wake — which is exactly the case worth waking for.
        ///
        /// ⚠️ **If you are here because the second wake "didn't fire" on a QA backend, it probably did.** Both
        /// emits below go through the *floored* fetch path, and the two instants are `G` apart — so whenever
        /// `G < SessionPro.StatusRefresh.floorSeconds` (60s) the first fetch arms the floor and the second is
        /// dropped. The wake was scheduled and did run; only its fetch was skipped, which is indistinguishable
        /// from never having been scheduled unless you know to look.
        ///
        /// Production `G` is ~1 hour so it can't happen there; a compressed testing backend sets it to ~10
        /// seconds. **Deliberately not worked around here** — the escape hatch is an env-var override of the
        /// floor, owned by the Pro UI-test work. Don't make these emits `immediate` to "fix" it: that would give
        /// two floor-exempt fetches on every renewal in production to serve a test-only configuration.
        var instants: [UInt64] = [expirySeconds + slackSeconds]

        if coverageEndSeconds != expirySeconds {
            instants.append(coverageEndSeconds + slackSeconds)
        }

        /// Re-derive the fired set against the instants currently scheduled, so a moved `E` forgets the old
        /// ones rather than accumulating them for the life of the process.
        firedUserExpiryWakeInstants = firedUserExpiryWakeInstants.intersection(instants)

        /// Anything already past — we were suspended across it, or the values arrived stale from another
        /// device. Mark them all and take **one** refresh: they ask the same question of the same fetch, and
        /// the trailing re-evaluation below re-arms whatever remains.
        let pastDueInstants: [UInt64] = instants.filter { nowSeconds >= $0 && !firedUserExpiryWakeInstants.contains($0) }

        guard pastDueInstants.isEmpty else {
            pastDueInstants.forEach { firedUserExpiryWakeInstants.insert($0) }
            try? await refreshProState()
            return
        }

        for instant in instants where !firedUserExpiryWakeInstants.contains(instant) {
            userExpiryWakeTasks.append(
                Task { [weak self] in
                    /// Integer `.seconds` overload — the `Double` one is iOS 16+.
                    do { try await Task.sleep(for: .seconds(Int(instant - nowSeconds))) }
                    catch { return }

                    await self?.fireUserExpiryStatusWake(atInstantSeconds: instant)
                }
            )
        }
    }

    /// Fire the wake for one instant, at most once for that instant.
    ///
    /// **Note:** when this is reached during a `refreshProState` that is still in flight, the refresh below is a
    /// no-op (`isRefreshingState`) — which is the right outcome: the in-flight fetch is itself the read the wake
    /// wanted, so the wake is legitimately consumed.
    private func fireUserExpiryStatusWake(atInstantSeconds instantSeconds: UInt64) async {
        guard !firedUserExpiryWakeInstants.contains(instantSeconds) else { return }

        /// Marked BEFORE the fetch deliberately: a failing network must not turn a one-shot wake into a refetch
        /// on every trigger that re-enters here. Recovering from a failed fetch belongs to the other triggers.
        firedUserExpiryWakeInstants.insert(instantSeconds)

        try? await refreshProState()
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
        let interval: TimeInterval = proofAcquisitionInterval(haveValidProof: haveValidProof)

        /// Spacing / best-effort single-flight / lost-completion recovery: if a request started too recently,
        /// just (re)arm the wake for when the interval elapses and bail.
        if (now - lastProofRequestAt) < interval {
            armProofRenewalWake(afterSeconds: ((lastProofRequestAt + interval) - now))
            return
        }

        lastProofRequestAt = now
        if !haveValidProof { darkAttempt += 1 }

        /// Arm the next wake now (it also re-checks a lost/frozen completion), then fire the generate.
        let nextInterval: TimeInterval = proofAcquisitionInterval(haveValidProof: haveValidProof)
        armProofRenewalWake(afterSeconds: nextInterval)
        startProofGeneration(nowUnixTimestampSeconds: nowSeconds)
    }

    /// The proof-acquisition spacing for the current pass — flat while covered, linear-with-cap while dark.
    ///
    /// Read twice per pass (once to decide whether to fire, once to arm the next wake), which is exactly why it is a
    /// function: the two must not be able to drift apart, and as duplicated literals they previously could.
    private func proofAcquisitionInterval(haveValidProof: Bool) -> TimeInterval {
        guard !haveValidProof else { return SessionPro.ProofAcquisition.coveredIntervalSeconds }

        return TimeInterval(
            min(
                SessionPro.ProofAcquisition.darkIntervalStepSeconds * darkAttempt,
                SessionPro.ProofAcquisition.darkIntervalCapSeconds
            )
        )
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

                    /// Keep `G` and `A` coherent with the `E` just written. Without this a proof outcome moves
                    /// the access expiry while leaving a grace period paired with the *previous* one, and
                    /// `E + G` — the coverage end the gate and the second wake are both derived from — silently
                    /// means nothing.
                    ///
                    /// `accountRenewalInfo` is `nil` unless this response actually carried a proof. That check
                    /// is the whole protection: on any other outcome libsession leaves these as the C struct's
                    /// zero-initialised defaults, which are indistinguishable from "no grace, not renewing" —
                    /// and writing that `false` would *erase* a flag `get_pro_status` had learned, because the
                    /// config keys are presence-only.
                    ///
                    /// 🔴 **The protection is the PLACEMENT, not the parse and not the type — do not hoist
                    /// these writes out of the success branch.** Reaching this line already implies success,
                    /// so the bind looks redundant here; it is what would fail loudly if the call ever moved,
                    /// and nothing else in this file would catch that.
                    if let renewalInfo: Network.SessionPro.GenerateProProofResponse.AccountRenewalInfo = response.accountRenewalInfo {
                        cache.updateProGracePeriodSeconds(renewalInfo.gracePeriodSeconds)
                        cache.updateProAutoRenewing(renewalInfo.autoRenewing)
                    }
                }
            }
        }

        /// Write the account triple straight to display state: a proof response is a response, and display state is
        /// owned by whichever response last spoke.
        ///
        /// 🔴 **Before the re-projection below, not after, and the ordering IS load-bearing.** Not because the
        /// projection would clobber it — it no longer writes these three — but because
        /// `updateWithLatestFromUserConfig` sees the config `E` just written, and its change trigger *awaits* a
        /// `get_pro_status`. That response is strictly newer than this one, so it has to be the one that survives.
        /// Writing afterwards would let this proof's `account_expiry` overwrite a status response that had already
        /// landed — the same "whichever ran last wins" bug this design removes, just between two responses instead
        /// of between config and a response.
        ///
        /// **The same two conditions as the config writes above, for the same reasons.** A response that carried no
        /// account expiry must not be read as "expires at 0", and on any non-success outcome libsession leaves the
        /// grace/renewal pair at the C struct's zero-initialised defaults, which are indistinguishable from "no
        /// grace, not renewing" — `accountRenewalInfo` is `nil` in exactly that case. Both fall back to
        /// `.useExisting` rather than to a zero value.
        let renewalInfo: Network.SessionPro.GenerateProProofResponse.AccountRenewalInfo? = response.accountRenewalInfo
        await updateProState(
            to: (await stateStream.getCurrent()).with(
                autoRenewing: (renewalInfo.map { .set(to: $0.autoRenewing) } ?? .useExisting),
                accessExpiryTimestampSeconds: (
                    response.accountExpiryTimestampSeconds > 0 ?
                        .set(to: response.accountExpiryTimestampSeconds) :
                        .useExisting
                ),
                gracePeriodSeconds: (renewalInfo.map { .set(to: $0.gracePeriodSeconds) } ?? .useExisting),
                using: dependencies
            )
        )

        /// Re-project the (now-updated) config into state — proof, rotating key and status re-derive consistently
        /// (and if the winning proof was an existing longer one, the rotating key matches it). It deliberately does
        /// **not** carry `E`/`G`/`A` any more, which is why they are written explicitly above.
        await updateWithLatestFromUserConfig()

        try? await Profile.updateLocal(proFeatures: syncState.state.profileFeatures, using: dependencies)
    }

    /// subscription_expired / not_subscribed clear — downgrade-guarded: apply only if there is no currently
    /// valid (unexpired) proof, read inside the write.
    private func applyProofClear() async {
        let nowSeconds: Int64 = Int64(await dependencies.networkOffsetTimestampMs() / 1000)

        /// Whether the clear actually applied — the downgrade guard decides, and the display write at the end
        /// needs the answer.
        ///
        /// The guard's read stays inside `mutate(cache:)`, which is the lock; `performAndPushChange` adds no
        /// further synchronisation of its own, so hoisting the read just outside it keeps the read and the write
        /// atomic with respect to an incoming merge exactly as before. A vetoed clear now also skips
        /// `performAndPushChange` entirely instead of entering it to make no change.
        let didClear: Bool = ((try? await dependencies[singleton: .storage].write { [dependencies] db -> Bool in
            try dependencies.mutate(cache: .libSession) { cache -> Bool in
                /// Downgrade guard (read live config): never wipe a fresh, unexpired proof another device
                /// just landed. `remove_pro_config` deliberately leaves `pro_prepaid` so a pending
                /// purchase keeps polling (§7.3).
                let hasUnexpiredProof: Bool = ((cache.proConfig?.proProof.expiryUnixTimestampSeconds ?? 0) > UInt64(max(0, nowSeconds)))
                guard !hasUnexpiredProof else { return false }

                try cache.performAndPushChange(db, for: .userProfile) { _ in
                    /// `remove_pro_config` clears ONLY the proof `s`. `E` does NOT self-age (unlike the proof
                    /// `I`/`R`), so a stale future `E` left here would make `pro_renewal_target` fire on every
                    /// eval and spin — clear it explicitly (`set_pro_access_expiry(nullopt)`, via `0`).
                    ///
                    /// **That also clears `G` and `A`**, inside libsession: both describe the subscription `E`
                    /// denotes, so a stranded grace period would pair with whatever `E` is written next, and a
                    /// stranded renewing flag would describe a subscription that no longer exists. Don't add
                    /// explicit clears for them here — the cascade is deliberate, and duplicating it would
                    /// invite someone to "tidy" the version that isn't load-bearing.
                    cache.removeProConfig()
                    cache.updateProAccessExpiryTimestampSeconds(0)
                }

                return true
            }
        }) ?? false)

        /// Only when the clear applied. If the downgrade guard vetoed, config now describes another device's
        /// fresher proof and display state must be left alone — clearing it here would throw away a newer
        /// `get_pro_status` answer on the strength of an outcome we just decided not to act on.
        ///
        /// Before the re-projection, for the reason spelled out in `applyProofSuccess`: clearing config `E` makes
        /// the change trigger fire, and the `get_pro_status` it awaits is strictly newer than this outcome. If the
        /// backend says the account is in fact still active, that answer has to survive rather than be cleared by
        /// a verdict we reached from a stale proof.
        if didClear {
            await clearProAccountDisplayState()
        }

        await updateWithLatestFromUserConfig()
    }

    /// `revoked` from a proof response is authoritative and terminal — clear regardless of validity. Clears
    /// both the proof `s` and the access-expiry `E`: `remove_pro_config` only clears `s`, and a stale future
    /// `E` would keep `pro_renewal_target` firing (spin), so clear it too (`set_pro_access_expiry(nullopt)`,
    /// via `0`).
    ///
    /// **Deliberately NOT the same as `clearOwnCredentialIfRevoked` (§6.4), and the difference is the source of
    /// the verdict.** Here the backend answered our proof request with `revoked`: that is terminal and about the
    /// account, so we clear `E` and there is nothing left to ask. §6.4 instead *infers* revocation by matching our
    /// own tag against the revocation list — a statement about one credential, not about entitlement — so it
    /// clears only the proof and then asks the server what the account's state actually is. Neither should be
    /// changed to match the other.
    private func applyProofRevoked() async {
        try? await dependencies[singleton: .storage].write { [dependencies] db in
            try dependencies.mutate(cache: .libSession) { cache in
                try cache.performAndPushChange(db, for: .userProfile) { _ in
                    cache.removeProConfig()
                    cache.updateProAccessExpiryTimestampSeconds(0)
                }
            }
        }

        /// Unconditional, unlike `applyProofClear` — `revoked` is terminal and has no downgrade guard to veto it.
        /// Before the re-projection, for the same ordering reason as the other two paths.
        await clearProAccountDisplayState()

        await updateWithLatestFromUserConfig()
    }

    /// Clear the account triple in **display** state.
    ///
    /// A cleared proof outcome is a response speaking too, and what it says is "you have nothing" — so it owns these
    /// three exactly as a success does. Config's version of this is a cascade inside libsession (clearing `E` clears
    /// `G` and `A` with it, since both describe the subscription `E` denotes); display state has no such cascade, so
    /// it is spelled out here.
    ///
    /// `status`, the proof and `profileFeatures` are not touched — `updateWithLatestFromUserConfig` re-derives those
    /// from the now-cleared config, and it still projects them.
    private func clearProAccountDisplayState() async {
        await updateProState(
            to: (await stateStream.getCurrent()).with(
                autoRenewing: .set(to: false),
                accessExpiryTimestampSeconds: .set(to: nil),
                gracePeriodSeconds: .set(to: 0),
                using: dependencies
            )
        )
    }

    // MARK: - Pro State Management
    
    private func updateProState(to newState: SessionPro.State) async {
        syncState.update(state: .set(to: newState))
        await self.stateStream.send(newState)
    }
    
    /// Whether a cold launch needs to go to the network for `get_pro_status`.
    ///
    /// Every client used to fetch unconditionally on startup — non-Pro users included — and a cold start is something
    /// mobile triggers constantly, so that was the bulk of the backend load for no benefit: entitlement comes from the
    /// proof, the settings screen refreshes on open, and account-expiry awareness is the `user_expiry` wake's job. The
    /// startup fetch's only real consumer is the home CTAs, so it is gated on "could a CTA fire", computed from synced
    /// config, plus a persisted min-interval.
    ///
    /// The test is against `E`, the date the renewal falls due — **not** against the end of coverage, `E + G`.
    /// Gating on `E + G` would put the whole grace window in the no-fetch branch, which is the one state this
    /// refresh design exists to surface. Both halves are synced (`E`, `G`), so the whole decision is
    /// config-derivable with no branching on provider or renewal state (`G` is 0 when not auto-renewing):
    ///
    /// | config state | action |
    /// |---|---|
    /// | `A && now < E`            | comfortably active, renewal not yet due → **no fetch** |
    /// | `A && E <= now < E + G`   | renewal due or overdue, still served → fetch, so grace can be surfaced while it is happening |
    /// | `!A && E` within the CTA window | expiring → fetch (the CTA is separately gated on the result) |
    /// | `now >= E + G`            | lapsed. Confirm-fetch first, so a renewal that landed elsewhere and hasn't
    ///                              synced can't produce a false "Pro expired" |
    ///
    /// Fetching once past `E` is still bounded on the far side by the persisted 24h interval below, which is what
    /// stops a lapsed account re-asking on every launch.
    ///
    /// **Not a Pro user at all** (no `E`, no proof) → never fetch. Note what that gives up: a purely server-side
    /// entitlement, e.g. a voucher, leaves no config trace, so this device won't discover it on its own. On iOS an
    /// Apple subscription still self-recovers through StoreKit (`Transaction.updates`), and everything else is what
    /// the manual recover action exists for.
    private func startupStatusFetchIsNeeded() async -> Bool {
        /// One mutation for all four, so they can't be read either side of an incoming config merge — `E` and `G`
        /// especially, since they are only comparable as the pair that arrived together.
        let (autoRenewing, expirySeconds, graceSeconds, hasProof): (Bool, UInt64, UInt64, Bool) = dependencies
            .mutate(cache: .libSession) {
                (
                    $0.proAutoRenewing,
                    $0.proAccessExpiryTimestampSeconds,
                    $0.proGracePeriodSeconds,
                    $0.proConfig?.proProof != nil
                )
            }

        /// Never subscribed as far as this device can tell — the case the gate exists to stop fetching for.
        guard expirySeconds > 0 || hasProof else {
            Log.info(.sessionPro, "Startup gate: no access expiry and no proof, skipping the startup fetch.")
            return false
        }

        /// Network time, not the device clock: skew must not be what flips a near-boundary `E` decision (and a device
        /// whose clock is days out would otherwise fetch, or fail to, on every launch).
        let nowSeconds: UInt64 = (await dependencies.networkOffsetTimestampMs() / 1000)

        guard await startupStatusFetchIsCTAWorthy(
            autoRenewing: autoRenewing,
            expirySeconds: expirySeconds,
            graceSeconds: graceSeconds,
            nowSeconds: nowSeconds
        ) else {
            Log.info(.sessionPro, "Startup gate: no CTA could fire, skipping the startup fetch.")
            return false
        }

        /// The gate's own rate limit. Checked last so a launch that wasn't CTA-worthy doesn't consume the interval.
        let lastStartupFetchSeconds: UInt64? = try? await dependencies[singleton: .storage].read { db in
            db[.proStatusLastStartupFetchAttemptTimestamp].map { UInt64(max(0, $0)) }
        }

        if
            let lastStartupFetchSeconds: UInt64,
            nowSeconds >= lastStartupFetchSeconds,
            (nowSeconds - lastStartupFetchSeconds) < SessionPro.StatusRefresh.startupMinIntervalSeconds
        {
            Log.info(
                .sessionPro,
                "Startup gate: fetched within the last \(SessionPro.StatusRefresh.startupMinIntervalSeconds)s, skipping the startup fetch."
            )
            return false
        }

        /// Recorded on the attempt, not on success: this bounds cold-start load, and a launch with no connectivity
        /// must not be able to retry on every relaunch. The other triggers still cover a genuinely needed refresh.
        try? await dependencies[singleton: .storage].write { db in
            db[.proStatusLastStartupFetchAttemptTimestamp] = Int(nowSeconds)
        }

        Log.info(
            .sessionPro,
            "Startup gate: a CTA could fire (autoRenewing: \(autoRenewing), expiry: \(expirySeconds), grace: \(graceSeconds)), fetching pro status."
        )

        return true
    }

    /// The CTA-worthiness half of the startup gate — the four rows of the table above, measured against `E` (the
    /// renewal date) rather than against the end of coverage `E + G`.
    ///
    /// The `!A && now < E` row outside the CTA window returns false (no fetch), and that is now **correct rather
    /// than merely assumed** — worth recording why, because it was held for a long time.
    ///
    /// `A` is stored presence-only: libsession's setter *erases* the key on false, so the key is present iff its
    /// value is 1, and "not auto-renewing" and "never written" are the same stored state. That is a property of
    /// the **encoding**, not of the accessor — a companion "has it ever been written" predicate cannot recover
    /// the distinction, which is why one built for exactly that was withdrawn as vacuous.
    ///
    /// So the row is only sound if absent-`A` genuinely means not-renewing, and the one path that could break
    /// that was the proof outcome: it writes `E`, and used to leave `A` alone, so an account renewed via a proof
    /// could hold a future `E` with no `A`. `applyProofSuccess` now writes `A` (and `G`) from the proof response
    /// whenever the backend supplies them, which closes it. Absent-`A` on a live account means not renewing.
    private func startupStatusFetchIsCTAWorthy(
        autoRenewing: Bool,
        expirySeconds: UInt64,
        graceSeconds: UInt64,
        nowSeconds: UInt64
    ) async -> Bool {
        /// The instant we stop being served: `E` plus however much longer the backend keeps serving past it. `G`
        /// is 0 whenever the subscription isn't auto-renewing, so this collapses to `E` there and needs no
        /// branching on provider or renewal state.
        ///
        /// Clamp rather than trap: these are `UInt64` and both arrive from **synced config**, so a corrupt value
        /// is reachable from another device rather than only from local logic — and an unsigned overflow there
        /// would crash on every launch, which is a worse failure than any wrong date.
        let coverageEndSeconds: UInt64 = (
            expirySeconds > (UInt64.max - graceSeconds) ? UInt64.max : expirySeconds + graceSeconds
        )

        /// Lapsed — past the end of coverage. Fetch to confirm before claiming expired, since a renewal may have
        /// landed elsewhere and not synced yet, but only while an Expired CTA could still fire.
        guard nowSeconds < coverageEndSeconds else {
            return ((nowSeconds - coverageEndSeconds) <= SessionPro.StatusRefresh.expiredCTAWindowSeconds)
        }

        /// Renewal due or overdue but still being served: the grace window `[E, E + G)`. **Always fetch** — this is
        /// the state the whole refresh design exists to surface, and gating on the coverage end instead is what
        /// would swallow it entirely. Empty when `!A`, since `G` is 0 there and this collapses into the branch above.
        guard nowSeconds < expirySeconds else { return true }

        /// Comfortably active and renewing itself — the case the gate exists to stop fetching for. The
        /// `user_expiry` wake covers the crossing; the config-change trigger covers another device.
        guard !autoRenewing else { return false }

        /// Not renewing and inside the CTA window — the Expiring CTA may be due.
        return ((expirySeconds - nowSeconds) <= SessionPro.StatusRefresh.expiringCTAWindowSeconds)
    }

    /// The drop-on-fresh status floor: whether enough time has passed since the last `get_pro_status` for a *routine*
    /// trigger to go to the network.
    ///
    /// Two exemptions, and the second one matters more than it looks:
    ///
    /// - `immediate` callers bypass it outright (manual/recover and the post-purchase poll).
    /// - **The first attempt of a process is never floored.** The persisted timestamp is what stops repeated cold
    ///   starts from hammering the backend, but it must not leave a *fresh* process unable to fetch at all:
    ///   `loadingState` would sit on its initial `.loading` with nothing to resolve it, which on this client means a
    ///   permanent spinner on the Pro screen and no CTA, since both gate on a confirmed fetch. Android gets this free
    ///   because its floor only applies once the load state leaves `Init`; this flag is the same condition. Note it is
    ///   keyed on having *attempted*, not succeeded — after a failure the state is `.error`, which the UI renders as a
    ///   retry (itself `immediate`), so the spinner problem is gone and there is no reason to keep bypassing.
    ///   Cold-start load stays bounded by the startup gate's own 24h interval, not by this floor.
    ///
    /// Fails **open** on a storage error — the floor is a backend-load optimisation, so an unreadable timestamp should
    /// cost an extra request rather than silently stop the client ever refreshing its status.
    private func statusFloorPermitsFetch(immediate: Bool) async -> Bool {
        guard !immediate else { return true }
        guard hasAttemptedStatusFetch else { return true }

        let lastFetchSeconds: UInt64? = try? await dependencies[singleton: .storage].read { db in
            db[.proStatusLastFetchAttemptTimestamp].map { UInt64(max(0, $0)) }
        }

        guard let lastFetchSeconds: UInt64 else { return true }

        let nowSeconds: UInt64 = (await dependencies.networkOffsetTimestampMs() / 1000)

        /// A timestamp in the future means the clock moved backwards; treat it as "just fetched" rather than as a
        /// licence to fetch, since the alternative lets a clock change unlock an unbounded run of requests.
        guard nowSeconds >= lastFetchSeconds else { return false }

        return ((nowSeconds - lastFetchSeconds) >= SessionPro.StatusRefresh.floorSeconds)
    }

    /// Record that a `get_pro_status` was **started** (not that it succeeded): the floor exists to bound requests, and
    /// a failing request costs the backend the same as a succeeding one.
    private func recordStatusFetchAttempt() async {
        let nowSeconds: UInt64 = (await dependencies.networkOffsetTimestampMs() / 1000)

        try? await dependencies[singleton: .storage].write { db in
            db[.proStatusLastFetchAttemptTimestamp] = Int(nowSeconds)
        }
    }

    public func refreshProState(immediate: Bool, forceLoadingState: Bool) async throws {
        /// No point refreshing the state if there is a refresh in progress
        ///
        /// **Note:** this is single-flight, *not* the floor — it stops concurrent fetches, not frequent ones, and
        /// `immediate` deliberately does not bypass it.
        guard !isRefreshingState else { return }

        /// Drop (don't re-arm) when the last fetch is still fresh. Deliberately before the loading-state change below,
        /// so a dropped refresh leaves the displayed state exactly as it was rather than parking it on a spinner.
        ///
        /// **Still reconcile the proof on the way out.** Every call to this function used to end in a
        /// `reconcileProofRenewal()`, and callers rely on that: when the proof loop is dormant
        /// (`pro_renewal_target == 0`) it has no wake of its own, so a nudge it would otherwise have received is not
        /// merely delayed, it is *lost*. Adding the floor must not silently remove that edge — most obviously for the
        /// case where the preceding fetch **failed**, which arms the floor (we stamp on attempt) without ever having
        /// reached its own reconcile. The reconcile is local and separately floored, so paying it on a dropped status
        /// refresh costs nothing.
        guard await statusFloorPermitsFetch(immediate: immediate) else {
            await reconcileProofRenewal()
            return
        }

        isRefreshingState = true
        defer { isRefreshingState = false }

        /// Arm the floor as soon as we commit to fetching, rather than on success — a request that fails costs the
        /// backend the same as one that succeeds, and recording it here means an early throw below can't leave the
        /// floor un-armed and the next trigger free to retry immediately.
        hasAttemptedStatusFetch = true
        await recordStatusFetchAttempt()

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
                gracePeriodSeconds: .set(to: response.gracePeriodDurationSeconds),
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

            /// `get_pro_status` is authoritative for the account expiry, so mirror `expiry_ts` into
            /// config `E` (`set_pro_access_expiry`) unconditionally on every success. This is the crux that
            /// lets `pro_renewal_target` fire for a server-side voucher / recovered subscription (account
            /// active but with no local proof yet) — without it, `E` in config would stay absent and a proof
            /// would never be fetched. libsession clears `E` when handed `<= 0` (the never/expired
            /// `expiry_ts`) and only dirties the config on a real change, so the unconditional write is safe.
            ///
            /// `auto_renewing` (config `A`) is mirrored on the same terms and in the same mutation: it is the
            /// other half of what the startup gate needs to decide whether a fetch is warranted before the
            /// network is available, and without it every cold launch would have to fetch to learn it. Same
            /// churn properties as `E` — libsession stores it presence-only and only dirties on a real change.
            try? await dependencies[singleton: .storage].write { [dependencies] db in
                try dependencies.mutate(cache: .libSession) { cache in
                    try cache.performAndPushChange(db, for: .userProfile) { _ in
                        cache.updateProAccessExpiryTimestampSeconds(response.expiryTimestampSeconds)
                        cache.updateProAutoRenewing(response.autoRenewing)
                        cache.updateProGracePeriodSeconds(response.gracePeriodDurationSeconds)
                    }
                }
            }

            /// `get_pro_status` is DISPLAY-ONLY for the PROOF (Rev 2 §1.3): it refreshes auto-renew / grace /
            /// refund / access-expiry fields but does NOT mint or clear the proof. The proof lifecycle — generate on
            /// due, and the §4 clears on `subscription_expired` / `not_subscribed` / `revoked` — is owned
            /// entirely by the reconcile loop's `generate_pro_proof` path, so we just kick a reconcile here
            /// (a status change may make a renewal / acquisition due).

            /// Stamp when this fetch completed, not when it started: a warning that keys off "we have asked
            /// since the threshold passed" must not be satisfied by a request that was already in flight when
            /// the threshold went by.
            updatedState = oldState.with(
                loadingState: .set(to: .success),
                lastConfirmedStatusFetchSeconds: .set(to: (await dependencies.networkOffsetTimestampMs() / 1000)),
                using: dependencies
            )

            syncState.update(state: .set(to: updatedState))
            await self.stateStream.send(updatedState)
            oldState = updatedState

            startStoreKitEntitlementsObservations()
            await entitlementsObservingTask?.value

            await reconcileProofRenewal()

            /// A successful fetch is the one thing that can advance `E`, so re-arm the `user_expiry` wake for
            /// whatever period we just learned about.
            await evaluateUserExpiryStatusWake()
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

            /// `immediate`: the user has just come back from Apple's manage-subscriptions sheet having possibly
            /// cancelled, and is looking at the screen waiting for it to reflect that. Same class as a manual refresh.
            try await refreshProState(immediate: true)
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

                                /// Same reasoning for the `user_expiry` wake: a `Task.sleep` doesn't survive
                                /// suspension, so this is what catches up an `E` crossing we slept through.
                                await self?.evaluateUserExpiryStatusWake()
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
    /// regardless of expiry — then refresh the account status so the server settles what the state now is.
    /// No-op when we hold no proof or it isn't revoked, so the refresh only happens on an actual revocation.
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

        /// 🔴 **Re-read the tag under the cache lock before clearing — the decision above is made outside it.**
        /// `removeProConfig` wipes whatever proof is stored, unconditionally, and the read that identified it as
        /// revoked happened in a *separate* lock acquisition. An incoming config merge mutates the libSession
        /// config object directly, so between the two a device can land a **new, unrevoked** proof — and clearing
        /// then throws away a valid credential on the strength of a verdict about the one it replaced. Actor
        /// isolation does not help: the storage write suspends, and the merge does not run on this actor.
        ///
        /// Same hazard, and the same shape, as `applyProofClear`'s downgrade guard.
        let didClear: Bool = ((try? await dependencies[singleton: .storage].write { [dependencies] db -> Bool in
            try dependencies.mutate(cache: .libSession) { cache -> Bool in
                guard
                    cache.proConfig?.proProof.revocationTag.toHexString() == ownProofRevocationTagHex
                else { return false }

                try cache.performAndPushChange(db, for: .userProfile) { _ in
                    cache.removeProConfig()
                }

                return true
            }
        }) ?? false)

        /// Nothing was cleared, so there is nothing to project or reconcile: either the proof had already been
        /// replaced, or the write failed and the next revocation-list fetch re-enters here. A merge that replaced
        /// it carries its own projection and refresh.
        ///
        /// Note this returns earlier than `applyProofClear`, which projects unconditionally even when its guard
        /// vetoes. The difference is what each path holds when it declines to act: that one is applying a *response*
        /// and still has its contents to project, whereas this one only ever had a local verdict about a credential —
        /// so when the verdict no longer applies there is nothing left to do here.
        guard didClear else { return }

        await updateWithLatestFromUserConfig()

        /// Then ask the server what the account's state actually is.
        ///
        /// **`E` is deliberately left alone**, unlike `applyProofRevoked`. A tag on the revocation list says this
        /// *credential* is dead; it does not say the *account* has lapsed, and only the server can tell us which.
        /// Clearing `E` here would be this client deciding the account's fate from a statement about one proof.
        ///
        /// 🔴 **This fetch is what makes leaving `E` safe — don't remove one without the other.** Nothing else on
        /// this path reaches the network: `updateWithLatestFromUserConfig` above is a projection, and its
        /// config-change trigger needs `E` or `I` to move, neither of which this path touches since it clears only
        /// the proof `s`. Drop the fetch and the account is left holding a stale future `E` with no proof and
        /// nothing scheduled to correct it — the `pro_renewal_target` spin that clearing `E` elsewhere avoids.
        ///
        /// Routine and floored, not `immediate`: nobody is waiting on a screen, and the floor exists for exactly
        /// this kind of background reconcile.
        try? await refreshProState()
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
    /// - Parameters:
    ///   - immediate: Bypass the status-refresh floor. **Reserved to the two genuine "go right now" callers** — a
    ///   manual refresh/recover the user is waiting on, and the bounded post-purchase poll — plus the bounded
    ///   while-open grace poll and developer-only paths, which the design lists as floor-exempt for the same reason
    ///   (they carry their own cadence and their own termination). Routine triggers (startup, config change, on-enter,
    ///   the `user_expiry` wake) must **not** pass it; a routine caller bypassing the floor is how the equivalent flag
    ///   on Android ended up dead in the first place.
    ///   - forceLoadingState: Show the spinner even when the current state isn't an error. **Orthogonal to
    ///   `immediate`** — spinner UI is a separate concern from bypassing the floor, and conflating them is what the
    ///   rename to `immediate` exists to prevent.
    func refreshProState(immediate: Bool, forceLoadingState: Bool) async throws
    @MainActor func requestRefund(scene: UIWindowScene) async throws
    @MainActor func cancelPro(scene: UIWindowScene) async throws
}

public extension SessionProManagerType {
    /// A routine, floored refresh with no spinner — the correct default for every trigger that isn't one of the
    /// explicitly floor-exempt ones.
    func refreshProState() async throws {
        try await refreshProState(immediate: false, forceLoadingState: false)
    }

    func refreshProState(immediate: Bool) async throws {
        try await refreshProState(immediate: immediate, forceLoadingState: false)
    }

    func refreshProState(forceLoadingState: Bool) async throws {
        try await refreshProState(immediate: false, forceLoadingState: forceLoadingState)
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
                        /// `immediate`: a developer flipping a mock in Developer Settings expects the change to take
                        /// effect now, and the floor would silently swallow rapid toggles. Developer-only path.
                        Task.detached { [weak self] in try await self?.refreshProState(immediate: true) }
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

