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
    case sessionRouter = 2
    case direct = 3
    
    // MARK: - Feature Option
    
    public static var defaultOption: Router = .onionRequests
    
    public var title: String {
        switch self {
            case .onionRequests: return "Onion Requests"
            case .sessionRouter: return "Session Router"
            case .direct: return "Direct"
        }
    }
    
    public var subtitle: String? {
        switch self {
            case .onionRequests: return "Requests will be encrypted in multiple layers and send via multiple hops in the network before going to their destination."
            case .sessionRouter: return "Requests will be sent via Session Router."
            case .direct: return "Requests will be sent directly to their destination."
        }
    }
}
