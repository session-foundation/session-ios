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

    /// The instant coverage ends: `E + G`. `G` is `0` when not auto-renewing, collapsing this to `E`.
    ///
    /// Saturates rather than traps: the operands come from synced config, so a corrupt value is reachable from
    /// another device and `+` on `UInt64` would crash at launch. Safe because entitlement comes from the proof.
    static func coverageEndSeconds(expirySeconds: UInt64, gracePeriodSeconds: UInt64) -> UInt64 {
        let (sum, overflowed) = expirySeconds.addingReportingOverflow(gracePeriodSeconds)

        return (overflowed ? .max : sum)
    }

    /// The `get_pro_status` refresh timings.
    ///
    /// A cross-client contract, not iOS tuning knobs: every client's refresh design is specified against these
    /// same values, so they move by agreement across clients or not at all.
    public enum StatusRefresh {
        /// Minimum gap between routine `get_pro_status` fetches. Drop-on-fresh, never re-arm: re-arming would turn every
        /// trigger into a once-a-minute poll that discovers nothing while `E` is static.
        ///
        /// Changing this needs the `user_expiry` wakes re-checked — both are floored and `G` apart, so where `G` is
        /// shorter the second wake's fetch is dropped.
        public static let floorSeconds: UInt64 = 60

        /// Minimum gap between startup-gate fetches. Cold starts are frequent on mobile, so the gate needs its
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

        /// The post-purchase chase (trigger #7). Floor-exempt, so these two are its bound: the window is measured
        /// from the FIRST request, and the gap is applied after each attempt SETTLES rather than as a fixed tick, so a
        /// slow onion request can never overlap itself.
        public static let postPurchasePollWindowSeconds: Int64 = 120
        public static let postPurchasePollGapSeconds: Int = 5
    }

    /// The proof-acquisition floor (Loop 1). Re-arms rather than drops — the opposite of the status floor above,
    /// because a throttled proof acquisition still has to happen, whereas a dropped status refresh is display-only
    /// and backstopped by the other triggers.
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
    private var accessObservationTask: Task<Void, Never>?
    private var appLifecycleObservingTask: Task<Void, Never>?

    /// Proof-renewal reconcile loop (Rev 2). `proofRenewalWakeTask` is the advisory in-foreground wake;
    /// `proofGenerationTask` is the in-flight `generate_pro_proof`. `lastProofRequestAt` + `darkAttempt`
    /// are ephemeral spacing/backoff state (re-derived from config each pass, reset on process death).
    private var proofRenewalWakeTask: Task<Void, Never>?
    private var proofGenerationTask: Task<Void, Never>?
    private var postPurchaseStatusPollTask: Task<Void, Never>?
    private var lastProofRequestAt: TimeInterval = -.greatestFiniteMagnitude
    private var darkAttempt: Int = 0

    /// The `user_expiry` status wakes: one advisory wake per scheduled instant, plus the instants already fired so
    /// each fires once per period. Must stay a collection — a single handle, cancelled once while scheduling two,
    /// orphans the first and leaks a timer per period without any test noticing.
    private var userExpiryWakeTasks: [Task<Void, Never>] = []
    private var firedUserExpiryWakeInstants: Set<UInt64> = []

    /// Config-change detection for the status trigger.
    ///
    /// These must not be display state: the display is owned by whichever response last spoke, so diffing it would
    /// stop the trigger firing for any account whose expiry came from a response — a dependency invisible at the
    /// diff site. `hasProjectedUserConfig` separates a process's first projection from a genuine change.
    private var lastKnownAccessExpirySeconds: UInt64 = 0
    private var lastKnownPrepaidTimestampSeconds: UInt64 = 0
    private var hasProjectedUserConfig: Bool = false

    /// The instant up to which we have already emitted "this profile's pro state just went stale" events
    ///
    /// Used as the lower bound of the window in `emitProInvalidationEvents(since:until:)` so that each lapse is emitted exactly
    /// once, and so a lapse that happened while the app was suspended is still caught on the next evaluation
    private var lastProInvalidationCheck: TimeInterval = 0

    private var isRefreshingState: Bool = false

    /// Whether a `get_pro_status` has been attempted this process; exempts the first attempt from the persisted
    /// floor. Without it, a relaunch inside the floor leaves `loadingState` on `.loading` with nothing to resolve it.
    private var hasAttemptedStatusFetch: Bool = false
    private var rotatingKeyPair: KeyPair?
    
    nonisolated private let stateStream: CurrentValueAsyncStream<SessionPro.State> = CurrentValueAsyncStream(.invalid)
    nonisolated private let hasCompletedInitialization: CurrentValueAsyncStream<Bool> = CurrentValueAsyncStream(false)

    /// The observable half of the access answer, fed from the two things which can change it: any state change (config
    /// projection, a response, a credential clear) and the invalidation wake (a proof reaching its expiry, a revocation
    /// reaching its `effective_at`).
    ///
    /// A dedicated carrier rather than a projection of `stateStream`, because the second of those is not a state change -
    /// nothing is written when an instant simply passes. Feeding it from ONE observer of `stateStream` rather than from
    /// each site which sends state is deliberate: a send site added later is covered without anyone remembering to.
    ///
    /// **Note:** `profileFeatures(for:)` needs none of this - the same wake already emits profile events, and that
    /// derivation re-runs against the current time, so the badge path is covered by a different route.
    nonisolated private let accessStream: CurrentValueAsyncStream<Bool> = CurrentValueAsyncStream(false)
    
    nonisolated public var currentUserCurrentRotatingKeyPair: KeyPair? { syncState.rotatingKeyPair }
    nonisolated public var currentUserCurrentProState: SessionPro.State { syncState.state }
    /// Whether this device may currently *use* Pro features - the **access** question, as distinct from `state.status`,
    /// which is the **display** question ("what state is the plan in", driving the settings row and the expiry CTAs).
    ///
    /// The two are meant to disagree. A subscription that has lapsed shows as expired while its proof is still live, and
    /// the features keep working until the proof itself does not - so a display value can never stand in for this one.
    ///
    /// Derived from the proof and **recomputed on every read**, never snapshotted: a proof expires, and a revocation
    /// becomes effective, at an instant no cached copy of this answer would notice.
    nonisolated public var currentUserHasProAccess: Bool {
        /// The proof mock, never the status mock: a mocked run holds no real proof, so if this consulted
        /// `mockCurrentUserSessionProBackendStatus` then "the plan is Active" would grant access as a side effect and
        /// display-Active-without-access - the state the message-truncation bug lives in - could not be reached by a test
        switch syncState.dependencies[feature: .mockCurrentUserSessionProProof] {
            case .simulate(let validity): return (validity == .valid)
            case .useActual:
                return currentUserProofIsValid(atTimestampMs: syncState.dependencies.networkOffsetTimestampMs())
        }
    }

    nonisolated public var pinnedConversationLimit: Int { SessionPro.PinnedConversationLimit }
    nonisolated public var characterLimit: Int {
        (
            currentUserHasProAccess ?
                SessionPro.ProCharacterLimit :
                SessionPro.CharacterLimit
        )
    }
    
    nonisolated public var state: AsyncStream<SessionPro.State> { stateStream.stream }
    /// **Note:** Emits the access answer recomputed at each state change rather than a projection of the emitted state -
    /// the state is the trigger, not the source. A revocation reaches this by clearing the proof, which is itself a state
    /// change; a bare `revocationList` update is not one, and does not need to be, since it cannot grant or remove access
    /// without that clear.
    nonisolated public var currentUserHasProAccessStream: AsyncStream<Bool> { accessStream.stream }

    /// Whether the user's PLAN reads active - the **display** question, and deliberately not
    /// `currentUserHasProAccess`.
    ///
    /// The distinction a caller has to make: a gate ("may I use this?") reads ACCESS, and anything explaining a gate
    /// to the user ("upgrade to send longer messages") reads DISPLAY. An upsell shown on ACCESS would offer Pro to
    /// someone whose plan is active but whose proof has not arrived - inviting them to buy what they already pay for.
    /// **Note:** A caller holding a `SessionPro.State` snapshot rather than this manager cannot reach this accessor and
    /// spells the predicate inline instead, so a change to what "active" MEANS - the obvious candidate being it coming
    /// to include the grace window, since `coverageEndTimestampSeconds` already exists - has to find those too. Grep
    /// `status == .active` rather than this symbol.
    nonisolated public var currentUserProPlanIsActive: Bool { syncState.state.status == .active }

    nonisolated public var currentUserProPlanIsActiveStream: AsyncStream<Bool> {
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
            await self?.startAccessObservation()
            await self?.startStoreKitObservations()
            await self?.startProInvalidationRescheduleObservations()
            await self?.scheduleNextProInvalidation()
            
            /// **Note:** No gated status fetch here. It hangs off `didBecomeActive` instead - see
            /// `startProInvalidationRescheduleObservations` - because a launch is not evidence of a foreground, and
            /// evaluating the gate without one spends an attempt-stamped budget where no CTA can be shown.

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
        accessObservationTask?.cancel()
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
    
    /// Whether `proof` is revoked as of `timestampMs`, honouring each item's effective instant
    ///
    /// Separate from `currentUserProofIsValid(atTimestampMs:)` because that one answers the question for our OWN proof and folds in
    /// expiry; this answers only "is this proof revoked", for a proof that arrived on a message.
    nonisolated public func proofIsRevoked(
        _ proof: Network.SessionPro.ProProof?,
        atTimestampMs timestampMs: UInt64
    ) -> Bool {
        guard let proof: Network.SessionPro.ProProof = proof else { return false }

        let nowSeconds: TimeInterval = TimeInterval(timestampMs / 1000)
        let proofRevocationTagHex: String = proof.revocationTag.toHexString()

        return syncState.revocationList.contains { item in
            TimeInterval(item.effectiveTimestampSeconds) <= nowSeconds &&
            item.revocationTag.toHexString() == proofRevocationTagHex
        }
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
                if !currentUserHasProAccess {
                    result = .none
                }
            case (.some(let proRevocationTagHex), let expiryUnixTimestampSeconds, _) where expiryUnixTimestampSeconds > 0:
                /// **Note:** A revocation item only takes effect once our clock reaches its `effectiveTimestampSeconds`, the backend
                /// can publish a revocation ahead of time so we need to keep honouring the proof until that instant passes
                let nowTimestampSeconds: TimeInterval = syncState.dependencies.networkOffsetDateNow()
                    .timeIntervalSince1970
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
    ) -> ProCTAOutcome {
        switch variant {
            /// The `groupLimit`, `animatedProfileImage`, and `expiring` CTA can be shown for Session Pro users as well
            ///
            /// **Why the guard below must not apply to these:** it exists to stop us inviting a user to buy Pro when
            /// their plan already reads active. These three are not that invitation - `groupLimit` asks whether the
            /// GROUP has Pro rather than the user, and `expiring`/`animatedProfileImage` are shown *because* of the
            /// user's own state rather than in spite of it.
            case .groupLimit, .animatedProfileImage, .expiring: break
            default:
                guard !currentUserProPlanIsActive else { return .suppressedPlanActive }
                
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
        
        return .shown
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
        let dateNow: Date = await dependencies.networkOffsetDateNow()

        /// Time remaining until the renewal falls due — positive before `E`, negative after it.
        let expiryInSeconds: TimeInterval = (state.accessExpiryTimestampSeconds
            .map { Date(timeIntervalSince1970: Double($0)).timeIntervalSince(dateNow) } ?? 0)

        /// Time elapsed since coverage ended — negative while still covered, positive once lapsed.
        ///
        /// Signed `TimeInterval`: `E + G` can sit ahead of `now` on clock skew or a config from another device, and an
        /// unsigned subtraction underflows to a huge positive that satisfies any upper bound. `nil` when no coverage end
        /// is known, since an account can report `.expired` with no expiry once history is pruned.
        let secondsSinceCoverageEnd: TimeInterval? = state.coverageEndTimestampSeconds
            .flatMap { coverageEnd in
                guard coverageEnd > 0 else { return nil }

                return dateNow.timeIntervalSince(Date(timeIntervalSince1970: Double(coverageEnd)))
            }
        let variant: ProCTAModal.Variant
        
        switch (state.status, state.autoRenewing, state.refundingStatus) {
            // Fail closed: an unrecognised backend status behaves like `.never` (no CTA, no Pro).
            case (.never, _, _), (.unknown, _, _), (.active, _, .refunding), (.active, true, .notRefunding): return nil
            case (.active, false, .notRefunding):
                /// Anchored at `E`: "your payment is due soon" is about the payment date, not about how long we keep serving.
                ///
                /// One-sided, so it also admits a negative interval — an `.active` account past `E`. Unreachable, but by an
                /// invariant elsewhere: `G` is 0 when not auto-renewing, so that would mean the backend serving past `E + 0`.
                guard
                    expiryInSeconds <= TimeInterval(SessionPro.StatusRefresh.expiringCTAWindowSeconds),
                    !dependencies[defaults: .standard, key: .hasShownProExpiringCTA]
                else { return nil }
                
                variant = .expiring(
                    timeLeft: expiryInSeconds.formatted(
                        format: .long,
                        allowedUnits: [ .day, .hour, .minute ]
                    )
                )
                
            case (.expired, _, _):
                /// Measured from coverage end, so the window is the same length whatever the store's grace is.
                ///
                /// Upper bound only: the backend forces `Expired` on revocation, so a refunded account reports `Expired` with
                /// its coverage end still ahead and a negative interval here.
                guard
                    let secondsSinceCoverageEnd: TimeInterval = secondsSinceCoverageEnd,
                    secondsSinceCoverageEnd < TimeInterval(SessionPro.StatusRefresh.expiredCTAWindowSeconds),
                    !dependencies[defaults: .standard, key: .hasShownProExpiredCTA]
                else { return nil }
                
                variant = .expiring(timeLeft: nil)
        }
        
        let nowMs: UInt64 = await dependencies.networkOffsetTimestampMs()
        let paymentFlow: SessionProPaymentScreenContent.SessionProPlanPaymentFlow = SessionProPaymentScreenContent.SessionProPlanPaymentFlow(
            state: state,
            nowSeconds: (nowMs / 1000),
            using: dependencies
        )
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
        ///
        /// `E` is consulted before the proof because they are evidence about different things: `E` arrived by config
        /// sync and is the backend's view of the ACCOUNT's plan, whereas a proof is this DEVICE's credential. A device
        /// restored from seed receives `E` before it acquires a proof, and reading the proof first tells such a user
        /// they have never subscribed.
        ///
        /// It is also the only ordering which can express a lapsed plan that is still being served: past `E` with a
        /// live proof displays as expired while access continues until the proof itself does. Reading the proof first
        /// collapses that to active.
        let nowMs: UInt64 = await dependencies.networkOffsetTimestampMs()
        let proStatus: Network.SessionPro.BackendUserProStatus = {
            let expirySeconds: UInt64 = proInfo.accessExpiryTimestampSeconds

            if expirySeconds > 0 {
                return ((nowMs / 1000) < expirySeconds ? .active : .expired)
            }

            /// The only rung which reads the proof, and it reads it through `proProofIsActive` - expiry alone. Not
            /// `currentUserProofIsValid`, which additionally consults the revocation list, and not
            /// `currentUserHasProAccess`, which is the access answer and is mockable. A revoked-but-unexpired
            /// credential therefore still seeds a display of active, which is correct: revocation withdraws what this
            /// device may DO, while what the plan SAYS is the backend's to state and arrives with a response.
            guard let proof: Network.SessionPro.ProProof = proInfo.proConfig?.proProof else {
                return .never
            }

            let proofIsActive: Bool = proProofIsActive(for: proof, atTimestampMs: nowMs)

            return (proofIsActive ? .active : .expired)
        }()
        let oldState: SessionPro.State = await stateStream.getCurrent()

        /// `E`, `G` and `A` are not projected here — their display copies are owned by whichever response last spoke,
        /// since only a response carries `latest_payment` and the rest that has to agree with them. Config keeps the
        /// three as the fetch trigger and the cross-device carrier, so every proof outcome writes the display itself.
        ///
        /// `E` deciding the status above is not in tension with that: a status is a claim the config alone can support,
        /// whereas a rendered DATE has to agree with `G` and `A`, which only a response carries. So `E` is read to
        /// choose active-vs-expired and still not projected as a value to show.
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

        /// A change to `E` or `I` means another device did something worth refreshing for; `I` is included because a
        /// purchase started elsewhere sets only `I`. Both diffed against the config values last seen, never display
        /// state. `G` is not watched — a grace change is the information, not a signal the server moved.
        let expiryChanged: Bool = (proInfo.accessExpiryTimestampSeconds != lastKnownAccessExpirySeconds)
        let prepaidChanged: Bool = (proInfo.prepaidTimestampSeconds != lastKnownPrepaidTimestampSeconds)
        let isFirstProjection: Bool = !hasProjectedUserConfig
        lastKnownAccessExpirySeconds = proInfo.accessExpiryTimestampSeconds
        lastKnownPrepaidTimestampSeconds = proInfo.prepaidTimestampSeconds
        hasProjectedUserConfig = true

        /// The first pass of a process is a projection of config we already had, not a config change. Treating it
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
    /// the "never settles" backstop — a single `refreshProState` can't hang indefinitely.)
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

            /// "No baseline yet" must stay distinguishable from "expires at 0": this poll starts before any response has
            /// landed, so collapsing an absent expiry to `0` makes the first response look like an advance and ends the poll
            /// on its first attempt.
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

    /// The `user_expiry` wakes: a refetch shortly after the renewal falls due, and a second shortly after coverage
    /// ends, each once per period. The proof is clamped well short of the account horizon, so without these an
    /// overdue renewal shows a stale "active". Advisory — `willEnterForeground` catches a crossing slept through.
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
        /// what we fired for, so a later subscription landing on the same instants isn't swallowed.
        guard expirySeconds > 0 else {
            firedUserExpiryWakeInstants = []
            return
        }

        /// With `G == 0` this yields `E`, so the two instants coincide and a single wake is scheduled — the right
        /// answer when there is no grace window to ask about separately.
        let coverageEndSeconds: UInt64 = SessionPro.coverageEndSeconds(
            expirySeconds: expirySeconds,
            gracePeriodSeconds: graceSeconds
        )
        let slackSeconds: UInt64 = SessionPro.StatusRefresh.userExpiryWakeSlackSeconds
        let nowSeconds: UInt64 = (await dependencies.networkOffsetTimestampMs() / 1000)

        /// Two instants: `E + 30s` asks whether the renewal charge succeeded, `(E + G) + 30s` whether grace ran out. The
        /// second is armed only when they don't coincide, which is the condition itself rather than a `G > 0` proxy.
        ///
        /// Not redundant with the proof loop landing near `E`: that reaches a status refresh only via the config-change
        /// trigger, which fires on `E` changing, and a failed renewal leaves `E` untouched.
        var instants: [UInt64] = [expirySeconds + slackSeconds]

        if coverageEndSeconds != expirySeconds {
            instants.append(coverageEndSeconds + slackSeconds)
        }

        /// Re-derive the fired set against the instants currently scheduled, so a moved `E` forgets the old
        /// ones rather than accumulating them for the life of the process.
        firedUserExpiryWakeInstants = firedUserExpiryWakeInstants.intersection(instants)

        /// Anything already past — we were suspended across it, or the values arrived stale from another device.
        /// Marking them fired here is what makes the arming loop below skip them, so there is one arming path
        /// rather than a past-due branch that has to remember to arm the rest.
        ///
        /// They ask the same question of the same fetch, so one refresh covers all of them, and it happens after
        /// arming: a refresh can return without reaching its own trailing re-evaluation — the single-flight guard,
        /// the floor and a non-success response all exit before it, and `try?` hides each — so anything not armed
        /// before that call may never be armed at all.
        let pastDueInstants: [UInt64] = instants.filter { nowSeconds >= $0 && !firedUserExpiryWakeInstants.contains($0) }

        pastDueInstants.forEach { firedUserExpiryWakeInstants.insert($0) }

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

        /// A side effect of the pass, not a step the arming depends on. Re-entrant — the refresh's own tail
        /// re-enters here — and it terminates: the past-due instants are in `fired` by now, so the re-entry finds
        /// none and issues no further refresh.
        guard !pastDueInstants.isEmpty else { return }

        try? await refreshProState()
    }

    /// Fire the wake for one instant, at most once for that instant. Floored, not `immediate`: this is a routine
    /// trigger. Both instants are armed by the same evaluation pass, so firing one does not need to arm the other.
    private func fireUserExpiryStatusWake(atInstantSeconds instantSeconds: UInt64) async {
        guard !firedUserExpiryWakeInstants.contains(instantSeconds) else { return }

        /// Marked before the fetch: a failing network must not turn a one-shot wake into a refetch
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
    /// Read twice per pass, and the two reads must agree or the loop arms a wake for an interval it didn't honour.
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
                    case .subscriptionExpired:
                        await applyProofClear(
                            accountState: response.accountRenewalInfo.map { renewal in
                                (
                                    expirySeconds: response.accountExpiryTimestampSeconds,
                                    gracePeriodSeconds: renewal.gracePeriodSeconds,
                                    autoRenewing: renewal.autoRenewing
                                )
                            }
                        )

                    case .notSubscribed:
                        await applyProofClear(accountState: nil)

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

                    /// Keep `G` and `A` coherent with the `E` just written: a grace period paired with the previous expiry makes
                    /// `E + G` meaningless.
                    ///
                    /// `accountRenewalInfo` is `nil` unless the outcome was success, which is the protection: on a transport
                    /// or protocol failure these are `0`/`false` parsed from nothing, and the config keys are presence-only, so
                    /// writing that `false` erases what `get_pro_status` learned. The protection is the placement — reaching this
                    /// line already implies success. A parsed `0`/`false` is a real answer and writing it is correct.
                    if let renewalInfo: Network.SessionPro.GenerateProProofResponse.AccountRenewalInfo = response.accountRenewalInfo {
                        cache.updateProGracePeriodSeconds(renewalInfo.gracePeriodSeconds)
                        cache.updateProAutoRenewing(renewalInfo.autoRenewing)
                    }
                }
            }
        }

        /// A proof response is a response, so it owns the display triple too.
        ///
        /// Must precede the re-projection: writing config `E` fires the change trigger, which awaits a `get_pro_status`
        /// — newer than this response, so it has to be the survivor. Same two conditions as the config writes above.
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
        /// not carry `E`/`G`/`A` any more, which is why they are written explicitly above.
        await updateWithLatestFromUserConfig()

        try? await Profile.updateLocal(proFeatures: syncState.state.profileFeatures, using: dependencies)
    }

    /// subscription_expired / not_subscribed clear — downgrade-guarded: apply only if there is no currently
    /// valid (unexpired) proof, read inside the write.
    /// - Parameter accountState: the expiry and its qualifiers to persist, or `nil` to clear all three.
    /// `subscription_expired` carries the account's real past expiry along with the grace and renewal flags that
    /// qualify it, and the backend sends them so a client can keep them; `not_subscribed` has no user row behind it,
    /// so there is genuinely nothing to record.
    private func applyProofClear(
        accountState: (expirySeconds: UInt64, gracePeriodSeconds: UInt64, autoRenewing: Bool)?
    ) async {
        let nowSeconds: Int64 = Int64(await dependencies.networkOffsetTimestampMs() / 1000)

        /// Whether the clear actually applied, which the display write at the end needs.
        ///
        /// The guard's read must stay inside `mutate(cache:)` — that closure is the lock, so the read and the write it
        /// authorises are atomic against an incoming merge.
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
                    /// This path must leave no `G` or `A` stranded beside the cleared `E`. They describe the
                    /// subscription `E` denotes, so a surviving grace period pairs with whatever `E` is written next
                    /// — silently changing where coverage ends — and a surviving renewing flag describes a
                    /// subscription that no longer exists, which the startup gate then reads as "still renewing".
                    ///
                    /// Clearing `E` is expected to take both with it, so no explicit clears appear here. If you are
                    /// reading this because they *are* being left behind, the obligation above is what has to hold —
                    /// add the clears here rather than treating it as cosmetic.
                    cache.removeProConfig()

                    /// `E` reflects what the backend last said, so it is cleared only when the backend says there is
                    /// nothing to say. An expired subscription still has an expiry, and it is the value the display
                    /// needs to say "renew" rather than "you never subscribed".
                    ///
                    /// All three are written together because `G` and `A` qualify whichever `E` is stored - writing an
                    /// expiry while leaving them behind pairs it with the previous subscription's grace, silently
                    /// moving where coverage ends, and leaves a renewing flag the startup gate reads as "still
                    /// renewing". The clear used to take them with it, so nothing here may write `E` alone.
                    cache.updateProAccessExpiryTimestampSeconds(accountState?.expirySeconds ?? 0)
                    cache.updateProGracePeriodSeconds(accountState?.gracePeriodSeconds ?? 0)
                    cache.updateProAutoRenewing(accountState?.autoRenewing ?? false)
                }

                return true
            }
        }) ?? false)

        /// Only when the clear applied: on a veto, config describes another device's fresher proof. Before the
        /// re-projection, since clearing `E` fires the change trigger and the response it awaits is newer.
        if didClear {
            await clearProAccountDisplayState()
        }

        await updateWithLatestFromUserConfig()

        /// Then ask, for the same reason as the revocation paths: the re-projection above reads config this function
        /// has just written, so it can only repeat what was already decided locally. The response is the one thing
        /// that can correct it - and on `not_subscribed`, where everything was cleared, it is the only way back to a
        /// state that says anything at all.
        try? await refreshProState(immediate: true)
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
                /// **Note:** The proof only. `E` is left alone, which is what the call site above already claims this
                /// path does - a revocation says this proof is void, not what the subscription is. A revocation which
                /// left the payments in place is a rotation: the account is still paid and re-provable, and nothing
                /// local separates that from a refund.
                ///
                /// `E` is also synced config rather than device-local, so clearing it here pushed that clear to every
                /// other device and erased the shared record that the user ever subscribed.
                try cache.performAndPushChange(db, for: .userProfile) { _ in
                    cache.removeProConfig()
                }
            }
        }

        /// Unconditional, unlike `applyProofClear` — `revoked` is terminal and has no downgrade guard to veto it.
        /// Before the re-projection, for the same ordering reason as the other two paths.
        await clearProAccountDisplayState()

        await updateWithLatestFromUserConfig()

        /// Then ask the server what the account actually is now, because neither choice about `E` is right on its own:
        /// after a refund the kept `E` is still the old FUTURE expiry, so the re-projection seeds `.active`, exactly as
        /// clearing it seeded `.never`. Only the response fixes it - the backend keeps the user row and writes
        /// `expiry_at = now`, so the status comes back expired with a real past expiry, which is mirrored into `E`.
        ///
        /// **Note:** `immediate`, which the routine triggers are told not to pass. This one qualifies on the terms that
        /// exemption is written for - it carries its own cadence and its own termination. A revocation is a discrete
        /// event rather than a poll; re-entry is bounded by the proof loop's dark backoff; and this fetch is what ENDS
        /// the loop, since the past expiry it writes stops the renewal target being acquired at all. Floored, the
        /// terminator is the first thing dropped - a status fetch at launch takes the interval and this refresh, which
        /// is the one that matters, is swallowed by it.
        try? await refreshProState(immediate: true)
    }

    /// Clear the account triple in display state — a cleared outcome is a response too, and it says "you have
    /// nothing". `status`, the proof and `profileFeatures` re-derive from the cleared config.
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
    
    /// Whether a cold launch needs to go to the network for `get_pro_status`. Gated on "could a CTA fire", computed
    /// from synced config, plus a persisted min-interval; entitlement itself comes from the proof.
    ///
    /// Measured against `E`, not `E + G` — gating on the coverage end would put the whole grace window in the
    /// no-fetch branch.
    ///
    /// | `A && now < E` | comfortably active → no fetch |
    /// | `A && E <= now < E + G` | renewal due, still served → fetch |
    /// | `!A && E` within the CTA window | expiring → fetch |
    /// | `now >= E + G` | lapsed → confirm-fetch, so a renewal landed elsewhere can't show a false expiry |
    ///
    /// No `E` and no proof → never fetch, which gives up discovering a server-side entitlement such as a voucher.
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

    /// The CTA-worthiness half of the gate, measured against `E`.
    ///
    /// The `!A && now < E` row is sound only because libsession erases `A` on false, making "not auto-renewing" and
    /// "never written" the same stored state. So it is an invariant the write side maintains: every path that writes
    /// `E` must write `A` alongside it, or a renewing account holds a future `E` with no `A` and this row calls it
    /// non-renewing.
    private func startupStatusFetchIsCTAWorthy(
        autoRenewing: Bool,
        expirySeconds: UInt64,
        graceSeconds: UInt64,
        nowSeconds: UInt64
    ) async -> Bool {
        /// The instant we stop being served, which is what the lapsed test below measures against.
        let coverageEndSeconds: UInt64 = SessionPro.coverageEndSeconds(
            expirySeconds: expirySeconds,
            gracePeriodSeconds: graceSeconds
        )

        /// Lapsed — past the end of coverage. Fetch to confirm before claiming expired, since a renewal may have
        /// landed elsewhere and not synced yet, but only while an Expired CTA could still fire.
        guard nowSeconds < coverageEndSeconds else {
            return ((nowSeconds - coverageEndSeconds) <= SessionPro.StatusRefresh.expiredCTAWindowSeconds)
        }

        /// Renewal due or overdue but still being served: the grace window `[E, E + G)`. Always fetch — this is
        /// the state the whole refresh design exists to surface, and gating on the coverage end instead is what
        /// would swallow it entirely. Empty when `!A`, since `G` is 0 there and this collapses into the branch above.
        guard nowSeconds < expirySeconds else { return true }

        /// Comfortably active and renewing itself — the case the gate exists to stop fetching for. The
        /// `user_expiry` wake covers the crossing; the config-change trigger covers another device.
        guard !autoRenewing else { return false }

        /// Not renewing and inside the CTA window — the Expiring CTA may be due.
        return ((expirySeconds - nowSeconds) <= SessionPro.StatusRefresh.expiringCTAWindowSeconds)
    }

    /// The drop-on-fresh status floor: whether enough time has passed since the last `get_pro_status` for a routine
    /// trigger to go to the network.
    ///
    /// Exempt: `immediate` callers, and a process's first attempt — without the second, a relaunch inside the floor
    /// leaves `loadingState` on `.loading` with nothing to resolve it. Keyed on attempted, not succeeded.
    ///
    /// Fails open on a storage error.
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

    /// Record that a `get_pro_status` was started (not that it succeeded): the floor exists to bound requests, and
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
        /// Note: this is single-flight, not the floor — it stops concurrent fetches, not frequent ones, and
        /// `immediate` does not bypass it.
        guard !isRefreshingState else { return }

        /// Drop rather than re-arm while the last fetch is fresh, and before the loading-state change so a dropped
        /// refresh leaves the display as it was.
        ///
        /// A dropped refresh must still reconcile the proof: when the proof loop is dormant it has no wake of its own,
        /// so a nudge it would have received is lost rather than delayed.
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
        let now: TimeInterval = await dependencies.networkOffsetDateNow().timeIntervalSince1970

        if lastProInvalidationCheck > 0 {
            await emitProInvalidationEvents(since: lastProInvalidationCheck, until: now)
        }

        /// An instant passing is not a state change, so this is the only thing that tells the access stream about it
        await emitAccessChange()

        lastProInvalidationCheck = now
    }

    /// How long to wait before the next instant, or `nil` if there's nothing upcoming
    private func nextProInvalidationDelay() async -> Int? {
        let now: TimeInterval = await dependencies.networkOffsetDateNow().timeIntervalSince1970

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

        /// Our OWN proof's expiry, named separately from the profile scan below rather than relied upon through it. The
        /// current user's profile row carries a copy of this instant, so the scan would usually find it - but "usually"
        /// is not a basis for the instant at which this device stops being allowed to use Pro
        let ownProofExpiry: TimeInterval? = syncState.state.proof
            .map { TimeInterval($0.expiryUnixTimestampSeconds) }
            .flatMap { $0 > now ? $0 : nil }

        /// Profiles need a query - there's no global in-memory profile cache to consult (`ConversationDataCache` is a
        /// per-observation snapshot). This runs on reschedule rather than per-frame, so a `MIN()` scan is fine.
        let nextExpiry: TimeInterval? = (try? await dependencies[singleton: .storage].read { db in
            try Profile.nextProExpiry(db, after: UInt64(max(0, now)))
        })
        .map { TimeInterval($0) }

        return [nextEffective, ownProofExpiry, nextExpiry].compactMap { $0 }.min()
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

        await notifyProStateRederivationNeeded(for: affectedProfiles)

        Log.info(.sessionPro, "Invalidated pro state for \(affectedProfiles.count) profile(s).")
    }

    /// Force a requery for profiles whose proof is revoked as of now, regardless of when it became effective
    ///
    /// `emitProInvalidationEvents(since:until:)` only covers instants that fall inside its window, which is the right rule for the
    /// passage of time but the wrong one for a list arriving: a revocation that was **already** effective when we fetched it has no
    /// instant left in the future to wake on, and its `effective_at` is usually behind the window's lower bound as well. Without this
    /// such a revocation is cached and correctly honoured while the badge stays on screen until something unrelated rebuilds the view.
    private func emitAlreadyEffectiveRevocationEvents() async {
        let nowSeconds: TimeInterval = await dependencies.networkOffsetDateNow().timeIntervalSince1970
        let effectiveTags: Set<String> = Set(
            syncState.revocationList
                .filter { TimeInterval($0.effectiveTimestampSeconds) <= nowSeconds }
                .map { $0.revocationTag.toHexString() }
        )

        guard !effectiveTags.isEmpty else { return }

        /// The window bounds are irrelevant here - passing an empty one leaves `revocationTagsHex` as the only clause that can match,
        /// which is exactly the "is this profile's proof revoked" question
        let revokedProfiles: [Profile]? = try? await dependencies[singleton: .storage].read { db in
            try Profile.withProStateInvalidated(db, since: 0, until: 0, revocationTagsHex: effectiveTags)
        }

        guard let revokedProfiles: [Profile], !revokedProfiles.isEmpty else { return }

        await notifyProStateRederivationNeeded(for: revokedProfiles)

        Log.info(.sessionPro, "Re-derived pro state for \(revokedProfiles.count) revoked profile(s).")
    }

    /// Emit the profile events that force a requery, which is what re-derives `profileFeatures(for:)` against the current time
    ///
    /// **Note:** Sends the profile's **stored** values - the row genuinely hasn't changed, and the direct-cache-update path writes
    /// these straight into the cached profile, so anything else here would corrupt it.
    private func notifyProStateRederivationNeeded(for profiles: [Profile]) async {
        await dependencies.notify(
            events: profiles.map { profile in
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
                    .appLifecycle(.didBecomeActive),
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

                            /// The gated status fetch hangs off *becoming active* rather than off launch or off
                            /// entering the foreground, because that is the only signal which covers both moments
                            /// without assuming anything about startup ordering: it fires on a cold launch into the
                            /// foreground AND on returning from the background, and it only fires when the app is
                            /// actually active, so the foreground-ness is inherent rather than asserted.
                            ///
                            /// Both moments are needed. The expiring CTA arms seven days before `E`, while the wakes
                            /// which survive suspension fire AT `E` and at coverage end - after that window has
                            /// opened - so a subscriber entering it while merely backgrounded would otherwise not be
                            /// warned until the process next started.
                            ///
                            /// It fires more often than a foreground transition does - dismissing a system alert,
                            /// returning from control centre, every activation - and that is affordable because the
                            /// gate checks its own 24h interval first: a fire inside the window costs one comparison
                            /// and reads nothing further.
                            if key == .appLifecycle(.didBecomeActive), await self?.startupStatusFetchIsNeeded() == true {
                                try? await self?.refreshProState()
                            }
                        }
                    }
                }
            }
        }
    }

    private func startAccessObservation() {
        accessObservationTask?.cancel()
        accessObservationTask = Task { [weak self, stateStream] in
            for await _ in stateStream.stream {
                guard !Task.isCancelled else { return }

                await self?.emitAccessChange()
            }
        }
    }

    private func emitAccessChange() async {
        await accessStream.send(currentUserHasProAccess)
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

            /// Automated tests only: backdate the stored instant so the gate below finds a poll due. The QA backend
            /// serves a `retry_in` of a day, which is inside libSession's clamp, so without this nothing after the
            /// first poll is observable in a test run.
            ///
            /// **Note:** This moves the gate's *input* and then leaves the gate alone, deliberately - a test-only fetch
            /// path could pass while the production one was broken. Applied once here rather than per iteration, so the
            /// server's cadence still governs every subsequent poll.
            if dependencies[feature: .forceProRevocationRefresh] {
                Log.warn(.sessionPro, "forceProRevocationRefresh is set; treating a revocation poll as due.")

                try? await dependencies[singleton: .storage].write { db in
                    db[.proRevocationsNextPollTimestamp] = 0
                }
            }
            
            while true {
                do {
                    /// The server owns this cadence, so honour the instant it implied even across a relaunch. Waiting
                    /// here rather than sleeping after the fetch means there is exactly one place that decides when the
                    /// next poll happens, and it reads persisted state - so a restart resumes the remainder of the
                    /// interval instead of starting a fresh one.
                    let nowSeconds: UInt64 = (await dependencies.networkOffsetTimestampMs() / 1000)
                    let nextPollSeconds: UInt64 = ((try? await dependencies[singleton: .storage].read { db in
                        db[.proRevocationsNextPollTimestamp].map { UInt64(max(0, $0)) }
                    }) ?? nil) ?? 0

                    if nextPollSeconds > nowSeconds {
                        try? await Task.sleep(for: .seconds(Int(nextPollSeconds - nowSeconds)))
                        continue
                    }

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

                    
                    /// A ticket that is already current comes back with an EMPTY item list rather than the list we
                    /// hold, so replacing unconditionally erased every revocation we knew about - and a recipient then
                    /// went back to honouring a proof it had already learnt was revoked. Only a response that advanced
                    /// the ticket carries a list worth storing. Session Desktop guards the same way.
                    let ticketAdvanced: Bool = (response.ticket > ticket)

                    /// The next-poll instant is written unconditionally: it is the cadence the backend asked for, and it
                    /// applies whether or not there was anything new. Written in the same transaction as the response it
                    /// came from, since a ticket that advanced without its matching instant would re-poll on the next
                    /// pass and defeat that cadence.
                    try await dependencies[singleton: .storage].write { db in
                        if ticketAdvanced {
                            db[.proRevocationsTicket] = Int(response.ticket)
                            db[.proRevocationList] = response.items
                        }
                        db[.proRevocationsNextPollTimestamp] = Int(nowSeconds + UInt64(max(0, response.retryInSeconds)))
                    }
                    
                    if ticketAdvanced {
                        syncState.update(revocationList: .set(to:response.items))
                    }

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

                    /// ...and anything already effective when it arrived has no upcoming instant for that to wake on
                    await emitAlreadyEffectiveRevocationEvents()
                    
                    Log.info(.sessionPro, (response.ticket != ticket ? "Successfully updated revocation list to \(response.ticket)." : "Revocation list already up-to-date."))

                    /// No sleep here - the persisted instant above is what the next iteration waits on. libSession
                    /// clamps `retry_in`/`retain_for` to sane bounds in its revocations parser, so we use it as-is.
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
        let nowSeconds: TimeInterval = await dependencies.networkOffsetDateNow().timeIntervalSince1970

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

        /// Re-read the tag under the cache lock before clearing. `removeProConfig` wipes whatever proof is stored, and
        /// the read that identified it as revoked happens in a separate lock acquisition — an incoming merge mutates the
        /// config object directly, so between the two a device can land a new, unrevoked proof. Actor isolation does not
        /// help: the storage write suspends and the merge does not run on this actor. Same guard as `applyProofClear`.
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

        /// Nothing was cleared, so nothing to project: the proof was already replaced, or the write failed and the next
        /// revocation-list fetch re-enters. Returns earlier than `applyProofClear`, which is applying a response and
        /// still has its contents to project.
        guard didClear else { return }

        await updateWithLatestFromUserConfig()

        /// Then ask the server what the account's state actually is. `E` is left alone: a revocation-list match says the
        /// credential is dead, not that the account lapsed.
        ///
        /// This fetch is what makes leaving `E` safe — nothing else on this path reaches the network, so without it the
        /// account holds a stale future `E` with no proof and nothing scheduled to correct it.
        ///
        /// **Note:** Immediate, because that is only true if the fetch arrives. Floored, a status fetch at launch takes
        /// the interval and this one is dropped - the revocation list is polled at launch too, so the two collide by
        /// default rather than by chance. Exempt on the same terms as the other revocation path: a discrete event
        /// which terminates itself once the response lands.
        try? await refreshProState(immediate: true)
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
    nonisolated func proofIsRevoked(
        _ proof: Network.SessionPro.ProProof?,
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
    ///   - immediate: Bypass the status-refresh floor. Reserved to callers that carry their own cadence and
    ///   termination — manual refresh/recover, the post-purchase poll, the while-open grace poll. Routine triggers
    ///   must not pass it; once they do, the floor stops bounding anything.
    ///   - forceLoadingState: Show the spinner even when the current state isn't an error. Orthogonal to
    ///   `immediate`.
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

