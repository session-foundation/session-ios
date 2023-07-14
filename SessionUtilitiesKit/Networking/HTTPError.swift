// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public enum HTTPError: LocalizedError, Equatable {
    case generic
    case invalidURL
    case invalidJSON
    case parsingFailed
    case invalidResponse
    case maxFileSizeExceeded
    case httpRequestFailed(statusCode: UInt, data: Data?)
    case timeout
    
    public var errorDescription: String? {
        switch self {
            case .generic: return "An error occurred."
            case .invalidURL: return "Invalid URL."
            case .invalidJSON: return "Invalid JSON."
            case .parsingFailed, .invalidResponse: return "Invalid response."
            case .maxFileSizeExceeded: return "Maximum file size exceeded."
            case .httpRequestFailed(let statusCode, _): return "HTTP request failed with status code: \(statusCode)."
            case .timeout: return "The request timed out."
        }
    }
}
