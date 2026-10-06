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
    
    /// Session Router is incomplete on this client, and a libSession build without session-router support throws when it
    /// is requested. Marking it invalid both hides it from `allCases` and makes a previously stored selection read back as
    /// `defaultOption`, so anyone who already chose it is moved off it rather than left on a router that can't work.
    /// Re-enabling needs a libSession build with session-router support and a working client implementation, not just
    /// this check removed.
    public static var allCases: [Router] { [.onionRequests, .sessionRouter, .direct].filter { $0.isValidOption } }
    
    // MARK: - Feature Option
    
    public static var defaultOption: Router = .onionRequests
    
    public var isValidOption: Bool { self != .sessionRouter }
    
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
