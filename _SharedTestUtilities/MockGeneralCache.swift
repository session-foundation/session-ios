// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUtilitiesKit

class MockGeneralCache: Mock<GeneralCacheType>, GeneralCacheType {
    var userExists: Bool {
        get { return mock() }
        set { mockNoReturn(args: [newValue]) }
    }
    
    var sessionId: SessionId {
        get { return mock() }
        set { mockNoReturn(args: [newValue]) }
    }
    
    var ed25519Seed: [UInt8] {
        get { return mock() }
        set { mockNoReturn(args: [newValue]) }
    }
    
    var ed25519SecretKey: [UInt8] {
        get { return mock() }
        set { mockNoReturn(args: [newValue]) }
    }
    
    var recentReactionTimestamps: [Int64] {
        get { return (mock() ?? []) }
        set { mockNoReturn(args: [newValue]) }
    }
    
    var contextualActionLookupMap: [Int: [String: [Int: Any]]] {
        get { return (mock() ?? [:]) }
        set { mockNoReturn(args: [newValue]) }
    }
    
    func setSecretKey(ed25519SecretKey: [UInt8]) {
        mockNoReturn(args: [ed25519SecretKey])
    }
}
