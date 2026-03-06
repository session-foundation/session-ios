// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil

public extension Network {
    enum RequestCategory: Int, Codable, CaseIterable {
        case standard
        case standardSmall
        case file
        case fileSmall
        case invalid
    }
}

extension Network.RequestCategory {
    public var libSessionValue: SESSION_NETWORK_REQUEST_CATEGORY {
        switch self {
            case .standard: return SESSION_NETWORK_REQUEST_CATEGORY_STANDARD
            case .standardSmall: return SESSION_NETWORK_REQUEST_CATEGORY_STANDARD_SMALL
            case .file: return SESSION_NETWORK_REQUEST_CATEGORY_FILE
            case .fileSmall: return SESSION_NETWORK_REQUEST_CATEGORY_FILE_SMALL
            case .invalid: return SESSION_NETWORK_REQUEST_CATEGORY_STANDARD
        }
    }
    
    public init(_ libSessionValue: SESSION_NETWORK_REQUEST_CATEGORY) {
        switch libSessionValue {
            case SESSION_NETWORK_REQUEST_CATEGORY_STANDARD: self = .standard
            case SESSION_NETWORK_REQUEST_CATEGORY_STANDARD_SMALL: self = .standardSmall
            case SESSION_NETWORK_REQUEST_CATEGORY_FILE: self = .file
            case SESSION_NETWORK_REQUEST_CATEGORY_FILE_SMALL: self = .fileSmall
            default: self = .standard
        }
    }
}
