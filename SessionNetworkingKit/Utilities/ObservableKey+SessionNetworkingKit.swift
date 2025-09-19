// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit

public extension ObservableKey {
    static func networkLifecycle(_ event: NetworkLifecycle) -> ObservableKey {
        ObservableKey("networkLifecycle-\(event)", .networkLifecycle)
    }
}

public extension GenericObservableKey {
    static let networkLifecycle: GenericObservableKey = "networkLifecycle"
}

// MARK: - NetworkLifecycle

public enum NetworkLifecycle: String, Sendable {
    case suspended
    case resumed
}
