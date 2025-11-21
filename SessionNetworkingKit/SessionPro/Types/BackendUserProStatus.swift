// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtil
import SessionUtilitiesKit

public extension Network.SessionPro {
    enum BackendUserProStatus: Sendable, CaseIterable, Equatable, CustomStringConvertible {
        case neverBeenPro
        case active
        case expired
        
        var libSessionValue: SESSION_PRO_BACKEND_USER_PRO_STATUS {
            switch self {
                case .neverBeenPro: return SESSION_PRO_BACKEND_USER_PRO_STATUS_NEVER_BEEN_PRO
                case .active: return SESSION_PRO_BACKEND_USER_PRO_STATUS_ACTIVE
                case .expired: return SESSION_PRO_BACKEND_USER_PRO_STATUS_EXPIRED
            }
        }
        
        init(_ libSessionValue: SESSION_PRO_BACKEND_USER_PRO_STATUS) {
            switch libSessionValue {
                case SESSION_PRO_BACKEND_USER_PRO_STATUS_NEVER_BEEN_PRO: self = .neverBeenPro
                case SESSION_PRO_BACKEND_USER_PRO_STATUS_ACTIVE: self = .active
                case SESSION_PRO_BACKEND_USER_PRO_STATUS_EXPIRED: self = .expired
                default: self = .neverBeenPro
            }
        }
        
        public var description: String {
            switch self {
                case .neverBeenPro: return "Never been pro"
                case .active: return "Active"
                case .expired: return "Expired"
            }
        }
    }
}

// MARK: - MockableFeature

public extension FeatureStorage {
    static let mockCurrentUserSessionProBackendStatus: FeatureConfig<MockableFeature<Network.SessionPro.BackendUserProStatus>> = Dependencies.create(
        identifier: "mockCurrentUserSessionProBackendStatus"
    )
}

extension Network.SessionPro.BackendUserProStatus: MockableFeatureValue {
    public var title: String { "\(self)" }
    
    public var subtitle: String {
        switch self {
            case .neverBeenPro: return "The user has never had Session Pro before."
            case .active: return "The user has an active Session Pro subscription."
            case .expired: return "The user's Session Pro subscription has expired."
        }
    }
}
