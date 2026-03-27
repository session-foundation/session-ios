// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil

public extension Network {
    enum PathCategory: Int, Codable, CaseIterable {
        case standard
        case file
        case invalid
    }
}

extension Network.PathCategory {
    public var libSessionValue: SESSION_NETWORK_PATH_CATEGORY {
        switch self {
            case .standard: return SESSION_NETWORK_PATH_CATEGORY_STANDARD
            case .file: return SESSION_NETWORK_PATH_CATEGORY_FILE
            case .invalid: return SESSION_NETWORK_PATH_CATEGORY_STANDARD
        }
    }
    
    public init(_ libSessionValue: SESSION_NETWORK_PATH_CATEGORY) {
        switch libSessionValue {
            case SESSION_NETWORK_PATH_CATEGORY_STANDARD: self = .standard
            case SESSION_NETWORK_PATH_CATEGORY_FILE: self = .file
            default: self = .standard
        }
    }
}
