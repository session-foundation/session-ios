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
        public let sessionProEnabled: Bool
        
        public let buildVariant: BuildVariant
        public let products: [Product]
        public let plans: [SessionPro.Plan]
        
        public let loadingState: SessionPro.LoadingState
        public let status: Network.SessionPro.BackendUserProStatus
        public let proof: Network.SessionPro.ProProof?
        public let profileFeatures: SessionPro.ProfileFeatures
        
        public let autoRenewing: Bool
        public let accessExpiryTimestampMs: UInt64?
        public let latestPaymentItem: Network.SessionPro.PaymentItem?
        public let originatingPlatform: SessionProUI.ClientPlatform
        public let originatingAccount: SessionPro.OriginatingAccount
        public let refundingStatus: SessionPro.RefundingStatus
    }
}

public extension SessionPro.State {
    static let invalid: SessionPro.State = SessionPro.State(
        sessionProEnabled: false,
        buildVariant: .appStore,
        products: [],
        plans: [],
        loadingState: .loading,
        status: .neverBeenPro,
        proof: nil,
        profileFeatures: .none,
        autoRenewing: false,
        accessExpiryTimestampMs: 0,
        latestPaymentItem: nil,
        originatingPlatform: .iOS,
        originatingAccount: .originatingAccount,
        refundingStatus: .notRefunding
    )
}

internal extension SessionPro.State {
    func with(
        products: Update<[Product]> = .useExisting,
        plans: Update<[SessionPro.Plan]> = .useExisting,
        loadingState: Update<SessionPro.LoadingState> = .useExisting,
        status: Update<Network.SessionPro.BackendUserProStatus> = .useExisting,
        proof: Update<Network.SessionPro.ProProof?> = .useExisting,
        profileFeatures: Update<SessionPro.ProfileFeatures> = .useExisting,
        autoRenewing: Update<Bool> = .useExisting,
        accessExpiryTimestampMs: Update<UInt64?> = .useExisting,
        latestPaymentItem: Update<Network.SessionPro.PaymentItem?> = .useExisting,
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
        let finalAccessExpiryTimestampMs: UInt64? = {
            let mockedValue: TimeInterval = dependencies[feature: .mockCurrentUserAccessExpiryTimestamp]
            
            guard mockedValue > 0 else { return accessExpiryTimestampMs.or(self.accessExpiryTimestampMs) }
            
            return UInt64(mockedValue)
        }()
        let finalLatestPaymentItem: Network.SessionPro.PaymentItem? = latestPaymentItem.or(self.latestPaymentItem)
        let finalOriginatingPlatform: SessionProUI.ClientPlatform = {
            switch dependencies[feature: .mockCurrentUserSessionProOriginatingPlatform] {
                case .simulate(let mockedValue): return mockedValue
                case .useActual: return SessionProUI.ClientPlatform(finalLatestPaymentItem?.paymentProvider)
            }
        }()
        
//        // TODO: [PRO] 'originatingAccount'?? I think we might need to check StoreKit transactions to see if they match the current one? (and if not then it's not the originating account?)
        
        let finalRefundingStatus: SessionPro.RefundingStatus = {
            switch dependencies[feature: .mockCurrentUserSessionProRefundingStatus] {
                case .simulate(let mockedValue): return mockedValue
                case .useActual:
                    return SessionPro.RefundingStatus(
                        finalStatus == .active &&
                        (finalLatestPaymentItem?.refundRequestedTimestampMs ?? 0) > 0
                    )
            }
        }()
        
        return SessionPro.State(
            sessionProEnabled: dependencies[feature: .sessionProEnabled],
            buildVariant: finalBuildVariant,
            products: products.or(self.products),
            plans: plans.or(self.plans),
            loadingState: finalLoadingState,
            status: finalStatus,
            proof: proof.or(self.proof),
            profileFeatures: profileFeatures.or(self.profileFeatures),
            autoRenewing: autoRenewing.or(self.autoRenewing),
            accessExpiryTimestampMs: finalAccessExpiryTimestampMs,
            latestPaymentItem: finalLatestPaymentItem,
            originatingPlatform: finalOriginatingPlatform,
            originatingAccount: .originatingAccount,
            refundingStatus: finalRefundingStatus
        )
    }
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

// MARK: - SessionPro.MockState

internal extension SessionPro {
    struct MockState: ObservableKeyProvider {
        struct Info: Sendable, Equatable {
            let sessionProEnabled: Bool
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
                (info.sessionProEnabled && !previousInfo.sessionProEnabled) ||
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
            .feature(.sessionProEnabled),
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
                sessionProEnabled: dependencies[feature: .sessionProEnabled],
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
    public var title: String { "\(self)" }
    
    public var subtitle: String {
        switch self {
            case .neverBeenPro: return "The user has never had Session Pro before."
            case .active: return "The user has an active Session Pro subscription."
            case .expired: return "The user's Session Pro subscription has expired."
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
    public var title: String { "\(self)" }
    
    public var subtitle: String {
        switch self {
            case .notRefunding: return "The Session Pro subscription does not currently have a pending refund."
            case .refunding: return "The Session Pro subscription currently has a pending refund."
        }
    }
}
