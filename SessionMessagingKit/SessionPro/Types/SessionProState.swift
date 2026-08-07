// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import StoreKit
import SessionUIKit
import SessionNetworkingKit
import SessionUtilitiesKit

public extension SessionPro {
    struct State: Sendable, Equatable, Hashable {
        public let buildVariant: BuildVariant
        public let products: [Product]
        public let plans: [SessionPro.Plan]
        public let entitledTransactions: [Transaction]
        
        public let loadingState: SessionPro.LoadingState
        public let status: Network.SessionPro.BackendUserProStatus
        public let proof: Network.SessionPro.ProProof?
        public let profileFeatures: SessionPro.ProfileFeatures
        
        public let autoRenewing: Bool
        public let accessExpiryTimestampSeconds: UInt64?
        /// Unix seconds at which a refund was requested (config-synced via `user_profile_get_refund_requested`),
        /// or `0` if none. Refund-pending is no longer a per-payment backend field — it's cross-device config
        /// state — so the manager reads it from libsession and stashes it here to drive `refundingStatus`.
        public let refundRequestedTimestampSeconds: UInt64
        public let latestPaymentItem: Network.SessionPro.PaymentItem?
        public let originatingPlatform: SessionProUI.ClientPlatform
        public let originatingAccount: SessionPro.OriginatingAccount
        public let refundingStatus: SessionPro.RefundingStatus

        /// Unix seconds at which the last `get_pro_status` **completed successfully**, or `0` if none has this
        /// process. `loadingState == .success` only says a fetch succeeded at *some* point; this says *when*, which is
        /// what a warning needs before it can claim the status behind it is post-threshold rather than a pre-crossing
        /// snapshot. Not persisted — a warning should re-confirm after a cold launch.
        ///
        /// **This is the "have we CONFIRMED?" value. Its counterpart is the "have we ASKED?" value**, the persisted
        /// `proStatusLastFetchAttemptTimestamp` backing the refresh floor. Substituting one for the other is the bug
        /// both names exist to prevent, so they are named after the question they answer rather than after what they
        /// are: anything gating a *display* claim reads this one; anything rate-limiting a *request* reads that one.
        ///
        /// **Sole consumer is `isRenewalOverdue(atTimestampSeconds:)`.** Dropping it and gating that on
        /// `loadingState == .success` alone is what shipped before, and it fires the alarming "renewal unsuccessful"
        /// copy off a **pre-crossing snapshot** the moment `E` passes — `.success` means "a fetch succeeded at some
        /// point", which at that instant is necessarily a fetch from before the threshold. Removable only once
        /// `loadingState` itself carries *when*; if that happens, delete this then and not before.
        public let lastConfirmedStatusFetchSeconds: UInt64

        /// 🔴 **The comment below asserts a premise that is WRONG, and the fix is deliberately not here.**
        /// `get_pro_status`'s `expiry_ts` is **grace-INCLUSIVE**: verified against `Session-Pro-Backend`
        /// @ `a5efbf9`, the backend folds grace in at *write* time
        /// (`payment_expiry_at = expiry_at + grace if auto_renewing`) and judges `Active`/`Expired` against
        /// that same value — its own test subtracts grace to recover the store's paid-through date. So this
        /// is **`coverage_end`**, not paid-through: `now ≥ E` is the grace **exit**, and the real grace
        /// window is `E − grace ≤ now < E`.
        ///
        /// Two consequences. The first is severe everywhere; the second's magnitude depends on the **payment
        /// provider**, which is *not* the same thing as the platform doing the displaying:
        /// - 🔴 **The real defect, provider-independent:** a grace indicator written as `now ≥ E` *inside* an
        ///   Active branch is **dead code**. Active requires `now ≤ E`, so the two meet only at a single
        ///   instant, and the "renewal overdue, still covered" state is therefore **unreachable** — which is
        ///   the entire state this refresh redesign exists to surface.
        /// - **A renewal date rendered as `E` is late by one grace period.** For an **App Store** payment
        ///   that is ~1 hour (Apple configures no grace period, so the backend's is entirely its own) and
        ///   effectively cosmetic. For a **Play Store** payment it is the base plan's operator-configured
        ///   grace — *days* — and the backend stores the real value at the moment the user **enters** grace,
        ///   i.e. exactly when this screen is the one they are looking at.
        ///
        /// **That second case reaches this client.** `latestPaymentItem.paymentProvider` can be `.playStore`
        /// (see `originatingPlatform`, which the grace modal interpolates as the store name), so a user who
        /// subscribed on Android and views on iOS gets the multi-day error here. Do not simplify this to
        /// "iOS is Apple, therefore an hour" — the purchase path is Apple-only, the *display* path is not.
        ///
        /// Not corrected here because all three clients wrote the same wrong premise in three different
        /// wordings — which is why it read as corroboration rather than one mistake — so the correction is
        /// one uniform change that must land on all three together. With the architect.
        ///
        /// Original text kept verbatim below, superseded, so it stays greppable alongside the Android and
        /// desktop copies it echoes:
        ///
        /// > Both the renewal countdown and the grace trigger key off the ACCOUNT paid-through end
        /// > (`get_pro_status` `expiry_ts`), never the latest payment's expiry — those differ when vouchers
        /// > or overlapping payments are involved. Matches Android/desktop.
        public var displayTimestampSeconds: UInt64? {
            accessExpiryTimestampSeconds
        }

        /// Whether we are past the account's paid-through end while still auto-renewing — i.e. the renewal is
        /// overdue but the account is still covered by the backend's grace period.
        ///
        /// **Debounced against the crossing**, which is the point: at the instant `E` passes, the newest
        /// status we hold was fetched *before* it, and a subscription that renewed cleanly looks identical to
        /// one that failed until we ask again. Requiring a fetch that completed at or after `E` is what stops
        /// the warning firing off that stale snapshot. The `E+30s` `user_expiry` wake is what supplies that
        /// fetch promptly; without it this would stay false for as long as nothing else went to the network.
        ///
        /// 🔴 **The THRESHOLD here inherits the wrong premise flagged on `displayTimestampSeconds` above.**
        /// `E` is grace-*inclusive*, so `now ≥ E` is the grace **exit** — on a correct reading this can only
        /// become true once coverage has fully lapsed, and the real window is `E − grace ≤ now < E`. The
        /// *debounce* (requiring a confirmed fetch past the threshold) is correct wherever the threshold
        /// sits; it is the comparison that moves. Left for the one uniform cross-client correction.
        public func isRenewalOverdue(atTimestampSeconds nowSeconds: UInt64) -> Bool {
            guard autoRenewing, let expirySeconds: UInt64 = accessExpiryTimestampSeconds, expirySeconds > 0 else {
                return false
            }

            return (nowSeconds >= expirySeconds && lastConfirmedStatusFetchSeconds >= expirySeconds)
        }
    }
}

public extension SessionPro.State {
    static let invalid: SessionPro.State = SessionPro.State(
        buildVariant: .appStore,
        products: [],
        plans: [],
        entitledTransactions: [],
        loadingState: .loading,
        status: .never,
        proof: nil,
        profileFeatures: .none,
        autoRenewing: false,
        accessExpiryTimestampSeconds: 0,
        refundRequestedTimestampSeconds: 0,
        latestPaymentItem: nil,
        originatingPlatform: .iOS,
        originatingAccount: .originatingAccount,
        refundingStatus: .notRefunding,
        lastConfirmedStatusFetchSeconds: 0
    )
}

internal extension SessionPro.State {
    func with(
        products: Update<[Product]> = .useExisting,
        plans: Update<[SessionPro.Plan]> = .useExisting,
        entitledTransactions: Update<[Transaction]> = .useExisting,
        loadingState: Update<SessionPro.LoadingState> = .useExisting,
        status: Update<Network.SessionPro.BackendUserProStatus> = .useExisting,
        proof: Update<Network.SessionPro.ProProof?> = .useExisting,
        profileFeatures: Update<SessionPro.ProfileFeatures> = .useExisting,
        autoRenewing: Update<Bool> = .useExisting,
        accessExpiryTimestampSeconds: Update<UInt64?> = .useExisting,
        refundRequestedTimestampSeconds: Update<UInt64> = .useExisting,
        latestPaymentItem: Update<Network.SessionPro.PaymentItem?> = .useExisting,
        lastConfirmedStatusFetchSeconds: Update<UInt64> = .useExisting,
        using dependencies: Dependencies
    ) -> SessionPro.State {
        let finalBuildVariant: BuildVariant = {
            switch dependencies[feature: .mockCurrentUserSessionProBuildVariant] {
                case .simulate(let mockedValue): return mockedValue
                case .useActual: return BuildVariant.current
            }
        }()
        let finalLoadingState: SessionPro.LoadingState = {
            switch dependencies[feature: .mockCurrentUserSessionProLoadingState] {
                case .simulate(let mockedValue): return mockedValue
                case .useActual: return loadingState.or(self.loadingState)
            }
        }()
        let finalStatus: Network.SessionPro.BackendUserProStatus = {
            switch dependencies[feature: .mockCurrentUserSessionProBackendStatus] {
                case .simulate(let mockedValue): return mockedValue
                case .useActual: return (status.or(self.status))
            }
        }()
        let finalAccessExpiryTimestampSeconds: UInt64? = {
            let mockedValue: TimeInterval = dependencies[feature: .mockCurrentUserAccessExpiryTimestamp]
            
            guard mockedValue > 0 else { return accessExpiryTimestampSeconds.or(self.accessExpiryTimestampSeconds) }
            
            return UInt64(mockedValue)
        }()
        let finalLatestPaymentItem: Network.SessionPro.PaymentItem? = latestPaymentItem.or(self.latestPaymentItem)
        let finalOriginatingPlatform: SessionProUI.ClientPlatform = {
            switch dependencies[feature: .mockCurrentUserSessionProOriginatingPlatform] {
                case .simulate(let mockedValue): return mockedValue
                case .useActual: return SessionProUI.ClientPlatform(finalLatestPaymentItem?.paymentProvider)
            }
        }()
        let finalEntitledTransactions: [Transaction] = entitledTransactions.or(self.entitledTransactions)
        let finalOriginatingAccount: SessionPro.OriginatingAccount = {
            switch dependencies[feature: .mockCurrentUserOriginatingAccount] {
                case .simulate(let mockedValue): return mockedValue
                case .useActual:
                    guard let lastPaymentItemAppleTransactionId: String = finalLatestPaymentItem?.appleTransactionId else {
                        return .nonOriginatingAccount
                    }
                    
                    let transactionIds: Set<String> = Set(finalEntitledTransactions.map { "\($0.id)" })
                    
                    return (transactionIds.contains(lastPaymentItemAppleTransactionId) ?
                        .originatingAccount :
                        .nonOriginatingAccount
                    )
            }
        }()
        
        let finalRefundRequestedTimestampSeconds: UInt64 = refundRequestedTimestampSeconds.or(self.refundRequestedTimestampSeconds)
        let finalRefundingStatus: SessionPro.RefundingStatus = {
            switch dependencies[feature: .mockCurrentUserSessionProRefundingStatus] {
                case .simulate(let mockedValue): return mockedValue
                case .useActual:
                    /// Refund-pending is config-synced state now (not a per-payment backend field); the
                    /// manager reads `user_profile_get_refund_requested` into `refundRequestedTimestampSeconds`.
                    return SessionPro.RefundingStatus(
                        finalStatus == .active &&
                        finalRefundRequestedTimestampSeconds > 0
                    )
            }
        }()
        
        return SessionPro.State(
            buildVariant: finalBuildVariant,
            products: products.or(self.products),
            plans: plans.or(self.plans),
            entitledTransactions: finalEntitledTransactions,
            loadingState: finalLoadingState,
            status: finalStatus,
            proof: proof.or(self.proof),
            profileFeatures: profileFeatures.or(self.profileFeatures),
            autoRenewing: autoRenewing.or(self.autoRenewing),
            accessExpiryTimestampSeconds: finalAccessExpiryTimestampSeconds,
            refundRequestedTimestampSeconds: finalRefundRequestedTimestampSeconds,
            latestPaymentItem: finalLatestPaymentItem,
            originatingPlatform: finalOriginatingPlatform,
            originatingAccount: finalOriginatingAccount,
            refundingStatus: finalRefundingStatus,
            lastConfirmedStatusFetchSeconds: lastConfirmedStatusFetchSeconds
                .or(self.lastConfirmedStatusFetchSeconds)
        )
    }
}

// MARK: - Convenience

extension SessionProUI.ClientPlatform {
    /// The originating platform the latest payment came from.
    ///
    /// **Note:** Only a Google Play payment maps to `.android`; App Store, non-store providers (e.g.
    /// stf), unknown/future providers, and "no latest payment" all collapse to `.iOS` (the local
    /// device). Mapping a `nil`/unknown provider to `.iOS` is a known limitation of the binary
    /// `ClientPlatform` — the true originating platform is unknown in those cases, so we fall back to the
    /// running device. A richer distinction is deferred to the display/i18n phase.
    init(_ provider: Network.SessionPro.PaymentProvider?) {
        switch provider {
            case .playStore: self = .android
            case .appStore, .stf, .other, .none: self = .iOS
        }
    }
}

// MARK: - SessionPro.MockState

internal extension SessionPro {
    struct MockState: ObservableKeyProvider {
        struct Info: Sendable, Equatable {
            let mockBuildVariant: MockableFeature<BuildVariant>
            let mockProLoadingState: MockableFeature<SessionPro.LoadingState>
            let mockProBackendStatus: MockableFeature<Network.SessionPro.BackendUserProStatus>
            let mockAccessExpiryTimestamp: TimeInterval
            let mockOriginatingPlatform: MockableFeature<SessionProUI.ClientPlatform>
            let mockOriginatingAccount: MockableFeature<SessionPro.OriginatingAccount>
            let mockRefundingStatus: MockableFeature<SessionPro.RefundingStatus>
        }
        
        let previousInfo: Info?
        let info: Info
        
        var needsRefresh: Bool {
            guard let previousInfo else { return false }
            
            func changedToUseActual<T>(
                _ keyPath: KeyPath<Info, MockableFeature<T>>
            ) -> Bool {
                switch (previousInfo[keyPath: keyPath], self.info[keyPath: keyPath]) {
                    case (.simulate, .useActual): return true
                    default: return false
                }
            }
            
            return (
                changedToUseActual(\.mockBuildVariant) ||
                changedToUseActual(\.mockProLoadingState) ||
                changedToUseActual(\.mockProBackendStatus) ||
                changedToUseActual(\.mockOriginatingPlatform) ||
                changedToUseActual(\.mockOriginatingAccount) ||
                changedToUseActual(\.mockRefundingStatus) ||
                (previousInfo.mockAccessExpiryTimestamp > 0 && info.mockAccessExpiryTimestamp == 0)
            )
        }
        
        let observedKeys: Set<ObservableKey> = [
            .feature(.mockCurrentUserSessionProBuildVariant),
            .feature(.mockCurrentUserSessionProLoadingState),
            .feature(.mockCurrentUserSessionProBackendStatus),
            .feature(.mockCurrentUserAccessExpiryTimestamp),
            .feature(.mockCurrentUserSessionProOriginatingPlatform),
            .feature(.mockCurrentUserOriginatingAccount),
            .feature(.mockCurrentUserSessionProRefundingStatus)
        ]
        
        init(previousInfo: Info? = nil, using dependencies: Dependencies) {
            self.previousInfo = previousInfo
            self.info = Info(
                mockBuildVariant: dependencies[feature: .mockCurrentUserSessionProBuildVariant],
                mockProLoadingState: dependencies[feature: .mockCurrentUserSessionProLoadingState],
                mockProBackendStatus: dependencies[feature: .mockCurrentUserSessionProBackendStatus],
                mockAccessExpiryTimestamp: dependencies[feature: .mockCurrentUserAccessExpiryTimestamp],
                mockOriginatingPlatform: dependencies[feature: .mockCurrentUserSessionProOriginatingPlatform],
                mockOriginatingAccount: dependencies[feature: .mockCurrentUserOriginatingAccount],
                mockRefundingStatus: dependencies[feature: .mockCurrentUserSessionProRefundingStatus]
            )
        }
    }
}


// MARK: - SessionPro.LoadingState

public extension FeatureStorage {
    static let mockCurrentUserSessionProLoadingState: FeatureConfig<MockableFeature<SessionPro.LoadingState>> = Dependencies.create(
        identifier: "mockCurrentUserSessionProLoadingState"
    )
}

extension SessionPro.LoadingState: MockableFeatureValue {
    public var rawValue: Int {
        switch self {
            case .loading: return 1
            case .error: return 2
            case .success: return 3
        }
    }

    public init?(rawValue: Int) {
        switch rawValue {
            case 1: self = .loading
            case 2: self = .error
            case 3: self = .success
            default: return nil
        }
    }

    public var title: String { "\(self)" }

    public var subtitle: String {
        switch self {
            case .loading: return "The UI state while we are waiting on the network response."
            case .error: return "The UI state when there was an error retrieving the users Pro status."
            case .success: return "The UI state once we have successfully retrieved the users Pro status."
        }
    }
}

// MARK: - Network.SessionPro.BackendUserProStatus

public extension FeatureStorage {
    static let mockCurrentUserSessionProBackendStatus: FeatureConfig<MockableFeature<Network.SessionPro.BackendUserProStatus>> = Dependencies.create(
        identifier: "mockCurrentUserSessionProBackendStatus"
    )
}

extension Network.SessionPro.BackendUserProStatus: @retroactive MockableFeatureValue {
    /// `.unknown` is a real-backend value deliberately excluded from `allCases`, so it isn't a mock-picker
    /// option and maps to `0` (no corresponding raw index); `init?(rawValue:)` only ever reconstructs the
    /// known `allCases` entries.
    public var rawValue: Int {
        switch self {
            case .never: return 1
            case .active: return 2
            case .expired: return 3
            case .unknown: return 0
        }
    }

    public init?(rawValue: Int) {
        switch rawValue {
            case 1: self = .never
            case 2: self = .active
            case 3: self = .expired
            default: return nil
        }
    }

    public var title: String { "\(self)" }

    public var subtitle: String {
        switch self {
            case .never: return "The user has never had Session Pro before."
            case .active: return "The user has an active Session Pro subscription."
            case .expired: return "The user's Session Pro subscription has expired."
            case .unknown(let code): return "Unrecognised backend status '\(code)' (treated as not-Pro)."
        }
    }
}

// MARK: - Access Expiry Timestamp

public extension FeatureStorage {
    static let mockCurrentUserAccessExpiryTimestamp: FeatureConfig<TimeInterval> = Dependencies.create(
        identifier: "mockCurrentUserAccessExpiryTimestamp"
    )
}

// MARK: - SessionProUI.ClientPlatform

public extension FeatureStorage {
    static let mockCurrentUserSessionProOriginatingPlatform: FeatureConfig<MockableFeature<SessionProUI.ClientPlatform>> = Dependencies.create(
        identifier: "mockCurrentUserSessionProOriginatingPlatform"
    )
}

extension SessionProUI.ClientPlatform: @retroactive CustomStringConvertible {
    public var description: String {
        switch self {
            case .iOS: return Constants.PaymentProvider.appStore.device
            case .android: return Constants.PaymentProvider.playStore.device
        }
    }
}

extension SessionProUI.ClientPlatform: @retroactive MockableFeatureValue {
    public var rawValue: Int {
        switch self {
            case .iOS: return 1
            case .android: return 2
        }
    }

    public init?(rawValue: Int) {
        switch rawValue {
            case 1: self = .iOS
            case 2: self = .android
            default: return nil
        }
    }

    public var title: String { "\(self)" }

    public var subtitle: String {
        switch self {
            case .iOS: return "The Session Pro subscription was originally purchased on an iOS device."
            case .android: return "The Session Pro subscription was originally purchased on an Android device."
        }
    }
}

// MARK: - OriginatingAccount.OriginatingAccount

public extension FeatureStorage {
    static let mockCurrentUserOriginatingAccount: FeatureConfig<MockableFeature<SessionPro.OriginatingAccount>> = Dependencies.create(
        identifier: "mockCurrentUserOriginatingAccount"
    )
}

extension SessionPro.OriginatingAccount: MockableFeatureValue {
    public var rawValue: Int {
        switch self {
            case .originatingAccount: return 1
            case .nonOriginatingAccount: return 2
        }
    }

    public init?(rawValue: Int) {
        switch rawValue {
            case 1: self = .originatingAccount
            case 2: self = .nonOriginatingAccount
            default: return nil
        }
    }

    public var title: String { "\(self)" }

    public var subtitle: String {
        switch self {
            case .originatingAccount: return "The Session Pro subscription was originally purchased on the account currently logged in."
            case .nonOriginatingAccount: return "The Session Pro subscription was originally purchased on a different account."
        }
    }
}

// MARK: - BuildVariant

public extension FeatureStorage {
    static let mockCurrentUserSessionProBuildVariant: FeatureConfig<MockableFeature<BuildVariant>> = Dependencies.create(
        identifier: "mockCurrentUserSessionProBuildVariant"
    )
}

extension BuildVariant: @retroactive MockableFeatureValue {
    public var rawValue: Int {
        switch self {
            case .appStore: return 1
            case .development: return 2
            case .testFlight: return 3
            case .ipa: return 4
            case .apk: return 5
            case .fDroid: return 6
            case .huawei: return 7
        }
    }

    public init?(rawValue: Int) {
        switch rawValue {
            case 1: self = .appStore
            case 2: self = .development
            case 3: self = .testFlight
            case 4: self = .ipa
            case 5: self = .apk
            case 6: self = .fDroid
            case 7: self = .huawei
            default: return nil
        }
    }

    public var title: String { "\(self)" }

    public var subtitle: String {
        switch self {
            case .appStore: return "The app was installed via the App Store."
            case .development: return "The app is a development build."
            case .testFlight: return "The app was installed via TestFlight."
            case .ipa: return "The app was installed direcrtly as an IPA."

            case .apk: return "The app was installed directly as an APK."
            case .fDroid: return "The app was installed via fDroid."
            case .huawei: return "The app is a Huawei build."
        }
    }
}

// MARK: - SessionPro.RefundingStatus

public extension FeatureStorage {
    static let mockCurrentUserSessionProRefundingStatus: FeatureConfig<MockableFeature<SessionPro.RefundingStatus>> = Dependencies.create(
        identifier: "mockCurrentUserSessionProRefundingStatus"
    )
}

extension SessionPro.RefundingStatus: MockableFeatureValue {
    public var rawValue: Int {
        switch self {
            case .notRefunding: return 1
            case .refunding: return 2
        }
    }

    public init?(rawValue: Int) {
        switch rawValue {
            case 1: self = .notRefunding
            case 2: self = .refunding
            default: return nil
        }
    }

    public var title: String { "\(self)" }

    public var subtitle: String {
        switch self {
            case .notRefunding: return "The Session Pro subscription does not currently have a pending refund."
            case .refunding: return "The Session Pro subscription currently has a pending refund."
        }
    }
}
