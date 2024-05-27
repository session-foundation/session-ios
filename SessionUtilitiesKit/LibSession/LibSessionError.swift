// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtil

public enum LibSessionError: Error, CustomStringConvertible {
    case unableToCreateConfigObject
    case invalidConfigObject
    case invalidDataProvided
    case userDoesNotExist
    case getOrConstructFailedUnexpectedly
    case processingLoopLimitReached
    case failedToRetrieveConfigData
    
    case libSessionError(String)
    
    public init(_ cError: [CChar]) {
        self = LibSessionError.libSessionError(String(cString: cError))
    }
    
    public init(_ errorString: String) {
        switch errorString {
            default: self = LibSessionError.libSessionError(errorString)
        }
    }
    
    public var description: String {
        switch self {
            case .unableToCreateConfigObject: return "Unable to create config object (LibSessionError.unableToCreateConfigObject)."
            case .invalidConfigObject: return "Invalid config object (LibSessionError.invalidConfigObject)."
            case .invalidDataProvided: return "Invalid data provided (LibSessionError.invalidDataProvided)."
            case .userDoesNotExist: return "User does not exist (LibSessionError.userDoesNotExist)."
            case .getOrConstructFailedUnexpectedly: return "'getOrConstruct' failed unexpectedly (LibSessionError.getOrConstructFailedUnexpectedly)."
            case .processingLoopLimitReached: return "Processing loop limit reached (LibSessionError.processingLoopLimitReached)."
            case .failedToRetrieveConfigData: return "Failed to retrieve config data."
            
            case .libSessionError(let error): return "\(error)\(period: error)"
        }
    }
}
