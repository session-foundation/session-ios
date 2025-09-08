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

// MARK: - Convenience

extension Mock where T == GeneralCacheType {
    func defaultInitialSetup() {
        self.when { $0.userExists }.thenReturn(true)
        self.when { $0.sessionId }.thenReturn(SessionId(.standard, hex: TestConstants.publicKey))
        self.when { $0.ed25519SecretKey }.thenReturn(Array(Data(hex: TestConstants.edSecretKey)))
        self
            .when { $0.ed25519Seed }
            .thenReturn(Array(Array(Data(hex: TestConstants.edSecretKey)).prefix(upTo: 32)))
    }
}
