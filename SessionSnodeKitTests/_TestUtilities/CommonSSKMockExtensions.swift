// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

@testable import SessionSnodeKit

extension Snode: Mocked {
    static var mockValue: Snode = Snode(
        ip: "test",
        lmqPort: 0,
        x25519PublicKey: TestConstants.edPublicKey,
        ed25519PublicKey: TestConstants.publicKey
    )
}
