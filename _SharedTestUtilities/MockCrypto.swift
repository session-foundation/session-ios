// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

class MockCrypto: Mock<CryptoType>, CryptoType {
    func size(_ size: Crypto.Size) -> Int {
        return accept(funcName: "size(\(size.id))", args: size.args) as! Int
    }
    
    func perform(_ action: Crypto.Action) throws -> Array<UInt8> {
        return try accept(funcName: "perform(\(action.id))", args: action.args) as? Array<UInt8> ?? {
            throw CryptoError.failedToGenerateOutput
        }()
    }
    
    func verify(_ verification: Crypto.Verification) -> Bool {
        return accept(funcName: "verify(\(verification.id))", args: verification.args) as! Bool
    }
    
    func generate(_ keyPairType: Crypto.KeyPairType) -> KeyPair? {
        return accept(funcName: "generate(\(keyPairType.id))", args: keyPairType.args) as? KeyPair
    }
    
    func generate(_ authInfo: Crypto.AuthenticationInfo) throws -> Authentication.Info {
        return try accept(funcName: "generate(\(authInfo.id))", args: authInfo.args) as? Authentication.Info ?? {
            throw CryptoError.failedToGenerateOutput
        }()
    }
    
    func generate(_ authSignature: Crypto.AuthenticationSignature) throws -> Authentication.Signature {
        return try accept(funcName: "generate(\(authSignature.id))", args: authSignature.args) as? Authentication.Signature ?? {
            throw CryptoError.failedToGenerateOutput
        }()
    }
}
