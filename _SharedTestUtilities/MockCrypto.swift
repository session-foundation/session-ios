// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

class MockCrypto: Mock<CryptoType>, CryptoType {
    func size(_ size: Crypto.Size) -> Int {
        return mock(funcName: "size(\(size.id))", args: size.args)
    }
    
    func perform(_ action: Crypto.Action) throws -> Array<UInt8> {
        return try mockThrowing(funcName: "perform(\(action.id))", args: action.args) ?? {
            throw CryptoError.failedToGenerateOutput
        }()
    }
    
    func verify(_ verification: Crypto.Verification) -> Bool {
        return mock(funcName: "verify(\(verification.id))", args: verification.args)
    }
    
    func generate(_ keyPairType: Crypto.KeyPairType) -> KeyPair? {
        return mock(funcName: "generate(\(keyPairType.id))", args: keyPairType.args)
    }
    
    func generate(_ authInfo: Crypto.AuthenticationInfo) throws -> Authentication.Info {
        return try mockThrowing(funcName: "generate(\(authInfo.id))", args: authInfo.args) ?? {
            throw CryptoError.failedToGenerateOutput
        }()
    }
    
    func generate(_ authSignature: Crypto.AuthenticationSignature) throws -> Authentication.Signature {
        return try mockThrowing(funcName: "generate(\(authSignature.id))", args: authSignature.args) ?? {
            throw CryptoError.failedToGenerateOutput
        }()
    }
}
