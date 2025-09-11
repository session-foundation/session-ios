// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit

// MARK: - FeatureStorage

public extension FeatureStorage {
    static let router: FeatureConfig<Router> = Dependencies.create(
        identifier: "router",
        defaultOption: .onionRequests
    )
}

// MARK: - Router

public enum Router: Int, Sendable, FeatureOption, CaseIterable {
    case onionRequests = 1
    case lokinet = 2
    case direct = 3
    
    // MARK: - Feature Option
    
    public static var defaultOption: Router = .onionRequests
    
    public var title: String {
        switch self {
            case .onionRequests: return "Onion Requests"
            case .lokinet: return "Lokinet"
            case .direct: return "Direct"
        }
    }
    
    public var subtitle: String? {
        switch self {
            case .onionRequests: return "Requests will be encrypted in multiple layers and send via multiple hops in the network before going to their destination."
            case .lokinet: return "Request will be sent via Lokinet."
            case .direct: return "Requests will be sent directly to their destination (This option is not currently supported)."
        }
    }
}
