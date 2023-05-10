// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Sodium

internal protocol ValidatableResponse {
    associatedtype ValidationData
    associatedtype ValidationResponse
    
    /// This valid controls the number of successful responses for a response to be considered "valid", a
    /// positive number indicates an exact number of responses required whereas a negative number indicates
    /// a dividing factor, eg.
    /// 2 = Two nodes need to have returned success responses
    /// -2 = 50% of the nodes need to have returned success responses
    /// -4 = 25% of the nodes need to have returned success responses
    static var requiredSuccessfulResponses: Int { get }
    
    static func validated(
        map validResultMap: [String: ValidationResponse],
        totalResponseCount: Int
    ) throws -> [String: ValidationResponse]
    
    func validResultMap(
        sodium: Sodium,
        userX25519PublicKey: String,
        validationData: ValidationData
    ) throws -> [String: ValidationResponse]
    
    func validateResultMap(sodium: Sodium, userX25519PublicKey: String, validationData: ValidationData) throws
}

// MARK: - Convenience

internal extension ValidatableResponse {
    func validateResultMap(sodium: Sodium, userX25519PublicKey: String, validationData: ValidationData) throws {
        _ = try validResultMap(
            sodium: sodium,
            userX25519PublicKey: userX25519PublicKey,
            validationData: validationData
        )
    }
    
    static func validated(
        map validResultMap: [String: ValidationResponse],
        totalResponseCount: Int
    ) throws -> [String: ValidationResponse] {
        let numSuccessResponses: Int = validResultMap.count
        let successPercentage: CGFloat = (CGFloat(numSuccessResponses) / CGFloat(totalResponseCount))
        
        guard
            (   // Positive value is an exact number comparison
                Self.requiredSuccessfulResponses >= 0 &&
                numSuccessResponses >= Self.requiredSuccessfulResponses
            ) || (
                // Negative value is a "divisor" for a percentage comparison
                Self.requiredSuccessfulResponses < 0 &&
                successPercentage >= abs(1 / CGFloat(Self.requiredSuccessfulResponses))
            )
        else { throw SnodeAPIError.responseFailedValidation }
        
        return validResultMap
    }
}

internal extension ValidatableResponse where ValidationData == Void {
    func validResultMap(sodium: Sodium, userX25519PublicKey: String) throws -> [String: ValidationResponse] {
        return try validResultMap(sodium: sodium, userX25519PublicKey: userX25519PublicKey, validationData: ())
    }
    
    func validateResultMap(sodium: Sodium, userX25519PublicKey: String) throws {
        _ = try validResultMap(
            sodium: sodium,
            userX25519PublicKey: userX25519PublicKey,
            validationData: ()
        )
    }
}

internal extension ValidatableResponse where ValidationResponse == Bool {
    static func validated(map validResultMap: [String: Bool]) throws -> [String: Bool] {
        return try validated(
            map: validResultMap.filter { $0.value },
            totalResponseCount: validResultMap.count
        )
    }
}
