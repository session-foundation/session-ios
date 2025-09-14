// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUtilitiesKit
import TestUtilities

class MockGeneralCache: GeneralCacheType, Mockable {
    public var handler: MockHandler<GeneralCacheType>
    
    required init(handler: MockHandler<GeneralCacheType>) {
        self.handler = handler
    }
    
    required init(handlerForBuilder: any MockFunctionHandler) {
        self.handler = MockHandler(forwardingHandler: handlerForBuilder)
    }
    
    var userExists: Bool {
        get { return handler.mock() }
        set { handler.mockNoReturn(args: [newValue]) }
    }
    
    var sessionId: SessionId {
        get { return handler.mock() }
        set { handler.mockNoReturn(args: [newValue]) }
    }
    
    var ed25519Seed: [UInt8] {
        get { return handler.mock() }
        set { handler.mockNoReturn(args: [newValue]) }
    }
    
    var ed25519SecretKey: [UInt8] {
        get { return handler.mock() }
        set { handler.mockNoReturn(args: [newValue]) }
    }
    
    var recentReactionTimestamps: [Int64] {
        get { return (handler.mock() ?? []) }
        set { handler.mockNoReturn(args: [newValue]) }
    }
    
    var contextualActionLookupMap: [Int: [String: [Int: Any]]] {
        get { return (handler.mock() ?? [:]) }
        set { handler.mockNoReturn(args: [newValue]) }
    }
    
    func setSecretKey(ed25519SecretKey: [UInt8]) {
        handler.mockNoReturn(args: [ed25519SecretKey])
    }
}

// MARK: - Convenience

extension MockGeneralCache {
    func defaultInitialSetup() async throws {
        try await self.when { $0.userExists }.thenReturn(true)
        try await self.when { $0.sessionId }.thenReturn(SessionId(.standard, hex: TestConstants.publicKey))
        try await self.when { $0.ed25519SecretKey }.thenReturn(Array(Data(hex: TestConstants.edSecretKey)))
        try await self.when { $0.setSecretKey(ed25519SecretKey: .any) }.thenReturn(())
        try await self
            .when { $0.ed25519Seed }
            .thenReturn(Array(Array(Data(hex: TestConstants.edSecretKey)).prefix(upTo: 32)))
    }
}
