// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit

public extension SessionPro {
    enum LoadingState: Sendable, CaseIterable, Equatable, CustomStringConvertible {
        case loading
        case error
        case success
        
        public var description: String {
            switch self {
                case .loading: return "Loading"
                case .error: return "Error"
                case .success: return "Success"
            }
        }
    }
}
