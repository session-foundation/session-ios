// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil

public extension Network {
    enum RequestCategory: Int, Codable, CaseIterable {
        case standard
        case upload
        case download
        case invalid
    }
}

extension Network.RequestCategory {
    public var libSessionValue: SESSION_NETWORK_REQUEST_CATEGORY {
        switch self {
            case .standard: return SESSION_NETWORK_REQUEST_CATEGORY_STANDARD
            case .upload: return SESSION_NETWORK_REQUEST_CATEGORY_UPLOAD
            case .download: return SESSION_NETWORK_REQUEST_CATEGORY_DOWNLOAD
            case .invalid: return SESSION_NETWORK_REQUEST_CATEGORY_STANDARD
        }
    }
    
    public init(_ libSessionValue: SESSION_NETWORK_REQUEST_CATEGORY) {
        switch libSessionValue {
            case SESSION_NETWORK_REQUEST_CATEGORY_STANDARD: self = .standard
            case SESSION_NETWORK_REQUEST_CATEGORY_UPLOAD: self = .upload
            case SESSION_NETWORK_REQUEST_CATEGORY_DOWNLOAD: self = .download
            default: self = .standard
        }
    }
}
