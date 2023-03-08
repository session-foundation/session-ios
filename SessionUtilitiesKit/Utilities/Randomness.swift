// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public enum Randomness {
    /// Returns `size` bytes of random data generated using the default secure random number generator. See
    /// [SecRandomCopyBytes](https://developer.apple.com/documentation/security/1399291-secrandomcopybytes) for more information.
    public static func generateRandomBytes(numberBytes: Int) throws -> Data {
        var randomBytes: Data = Data(count: numberBytes)
        let result = randomBytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, numberBytes, $0.baseAddress!)
        }
        
        guard result == errSecSuccess, randomBytes.count == numberBytes else {
            print("Problem generating random bytes")
            throw GeneralError.randomGenerationFailed
        }
        
        return randomBytes
    }
}
