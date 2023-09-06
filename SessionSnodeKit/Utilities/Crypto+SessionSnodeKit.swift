// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Sodium
import SessionUtilitiesKit

// MARK: - Sign

public extension Crypto.Action {
    static func signature(message: Bytes, secretKey: Bytes) -> Crypto.Action {
        return Crypto.Action(id: "signature", args: [message, secretKey]) {
            Sodium().sign.signature(message: message, secretKey: secretKey)
        }
    }
}

public extension Crypto.Verification {
    static func signature(message: Bytes, publicKey: Bytes, signature: Bytes) -> Crypto.Verification {
        return Crypto.Verification(id: "signature", args: [message, publicKey, signature]) {
            Sodium().sign.verify(message: message, publicKey: publicKey, signature: signature)
        }
    }
}
