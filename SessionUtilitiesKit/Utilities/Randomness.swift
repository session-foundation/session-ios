// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public enum Randomness {
    public static func generateRandomBytes(numberBytes: Int) throws -> Data {
        var randomByes: Data = Data(count: numberBytes)
        let result = randomByes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, numberBytes, $0.baseAddress!)
        }
        
        guard result == errSecSuccess, randomByes.count == numberBytes else {
            print("Problem generating random bytes")
            throw GeneralError.randomGenerationFailed
        }
        
        return randomByes
    }
}
