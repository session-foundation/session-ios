// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Sodium
import Curve25519Kit
import SessionUtilitiesKit

extension KeyPair: Mocked {
    static var mockValue: KeyPair = KeyPair(
        publicKey: Data(hex: TestConstants.publicKey).bytes,
        secretKey: Data(hex: TestConstants.edSecretKey).bytes
    )
}

extension ECKeyPair: Mocked {
    static var mockValue: Self {
        try! Self.init(
            publicKeyData: Data(hex: TestConstants.publicKey),
            privateKeyData: Data(hex: TestConstants.privateKey)
        )
    }
}
