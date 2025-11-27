// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUIKit
import SessionNetworkingKit
import SessionUtilitiesKit

// MARK: - SessionProManager.MockState

internal extension SessionProManager {
    struct MockState: ObservableKeyProvider {
        struct Info: Sendable, Equatable {
            let sessionProEnabled: Bool
            let mockProLoadingState: MockableFeature<SessionPro.LoadingState>
            let mockProBackendStatus: MockableFeature<Network.SessionPro.BackendUserProStatus>
            let mockOriginatingPlatform: MockableFeature<SessionProUI.ClientPlatform>
            let mockIsRefunding: MockableFeature<SessionPro.IsRefunding>
        }
        
        let previousInfo: Info?
        let info: Info
        
        let observedKeys: Set<ObservableKey> = [
            .feature(.sessionProEnabled),
            .feature(.mockCurrentUserSessionProLoadingState),
            .feature(.mockCurrentUserSessionProBackendStatus),
            .feature(.mockCurrentUserSessionProOriginatingPlatform),
            .feature(.mockCurrentUserSessionProIsRefunding)
        ]
        
        init(previousInfo: Info? = nil, using dependencies: Dependencies) {
            self.previousInfo = previousInfo
            self.info = Info(
                sessionProEnabled: dependencies[feature: .sessionProEnabled],
                mockProLoadingState: dependencies[feature: .mockCurrentUserSessionProLoadingState],
                mockProBackendStatus: dependencies[feature: .mockCurrentUserSessionProBackendStatus],
                mockOriginatingPlatform: dependencies[feature: .mockCurrentUserSessionProOriginatingPlatform],
                mockIsRefunding: dependencies[feature: .mockCurrentUserSessionProIsRefunding]
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

// MARK: - SessionPro.IsRefunding

public extension FeatureStorage {
    static let mockCurrentUserSessionProIsRefunding: FeatureConfig<MockableFeature<SessionPro.IsRefunding>> = Dependencies.create(
        identifier: "mockCurrentUserSessionProIsRefunding"
    )
}

extension SessionPro.IsRefunding: MockableFeatureValue {
    public var title: String { "\(self)" }
    
    public var subtitle: String {
        switch self {
            case .notRefunding: return "The Session Pro subscription does not currently have a pending refund."
            case .refunding: return "The Session Pro subscription currently has a pending refund."
        }
    }
}
