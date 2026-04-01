// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

public enum NetworkError: Error, Equatable, CustomStringConvertible {
    case invalidState
    case invalidURL
    case invalidRequest
    case forbidden
    case notFound
    case parsingFailed
    case invalidPayload
    case invalidResponse
    case maxFileSizeExceeded
    case unauthorised
    case internalServerError
    case badGateway
    case serviceUnavailable
    case gatewayTimeout
    case badRequest(error: String, rawData: Data?)
    case requestFailed(error: String, rawData: Data?)
    case timeout(error: String, rawData: Data?)
    case explicit(String)
    case suspended
    case unknown
    
    public var description: String {
        switch self {
            case .invalidState: return "The network is in an invalid state (NetworkError.invalidState)."
            case .invalidURL: return "Invalid URL (NetworkError.invalidURL)."
            case .invalidRequest: return "Invalid Request provided (NetworkError.invalidRequest)."
            case .forbidden: return "Forbidden (403 - NetworkError.forbidden)."
            case .notFound: return "Not Found (404 - NetworkError.notFound)."
            case .parsingFailed: return "Invalid response (NetworkError.parsingFailed)."
            case .invalidPayload: return "Invalid payload (NetworkError.invalidPayload)."
            case .invalidResponse: return "Invalid response (NetworkError.invalidResponse)."
            case .maxFileSizeExceeded: return "Maximum file size exceeded (NetworkError.maxFileSizeExceeded)."
            case .unauthorised: return "Unauthorised (401, likely failed to verify the signature - NetworkError.unauthorised)."
            case .internalServerError: return "Internal server error (500 - NetworkError.internalServerError)."
            case .badGateway: return "Bad gateway (502 - NetworkError.badGateway)."
            case .serviceUnavailable: return "Service unavailable (503 - NetworkError.serviceUnavailable)."
            case .gatewayTimeout: return "Gateway timeout (504 - NetworkError.gatewayTimeout)."
            case .badRequest(let error, _), .requestFailed(let error, _): return error
            case .timeout(let error, _): return "The request timed out with error: \(error) (NetworkError.timeout)."
            case .explicit(let error): return error
            case .suspended: return "Network requests are suspended (NetworkError.suspended)."
            case .unknown: return "An unknown error occurred (NetworkError.unknown)."
        }
    }
}
