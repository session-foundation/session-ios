// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtil
import SessionUtilitiesKit

public extension Network.SessionPro {
    enum BackendUserProStatus: Sendable, CaseIterable, CustomStringConvertible {
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

// MARK: - FeatureStorage

public extension FeatureStorage {
    static let mockCurrentUserSessionProBackendStatus: FeatureConfig<Network.SessionPro.BackendUserProStatus?> = Dependencies.create(
        identifier: "mockCurrentUserSessionProBackendStatus"
    )
}

// MARK: - Router

extension Optional: @retroactive RawRepresentable, @retroactive FeatureOption where Wrapped == Network.SessionPro.BackendUserProStatus {
    public typealias RawValue = Int
    
    public var rawValue: Int {
        switch self {
            case .none: return -1
            case .neverBeenPro: return 1
            case .active: return 2
            case .expired: return 3
        }
    }
    
    public init?(rawValue: Int) {
        switch rawValue {
            case 1: self = .neverBeenPro
            case 2: self = .active
            case 3: self = .expired
            default: self = nil
        }
    }
    
    // MARK: - Feature Option
    
    public static var defaultOption: Network.SessionPro.BackendUserProStatus? = nil
    
    public var title: String { (self.map { "\($0)" } ?? "None") }
    
    public var subtitle: String? {
        switch self {
            case .none: return "Use the current users <i>actual</i> status."
            case .neverBeenPro: return "The user has never had Session Pro before."
            case .active: return "The user has an active Session Pro subscription."
            case .expired: return "The user's Session Pro subscription has expired."
        }
    }
}
