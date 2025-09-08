// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit
import TestUtilities

class MockCrypto: CryptoType, Mockable {
    nonisolated let handler: MockHandler<CryptoType>
    
    required init(handler: MockHandler<CryptoType>) {
        self.handler = handler
    }
    
    required init(handlerForBuilder: any MockFunctionHandler) {
        self.handler = MockHandler(forwardingHandler: handlerForBuilder)
    }
    
    func tryGenerate<R>(_ generator: Crypto.Generator<R>) throws -> R {
        return try handler.mockThrowing(funcName: "generate<\(R.self)>(\(generator.id))", args: generator.args)
    }
    
    func verify(_ verification: Crypto.Verification) -> Bool {
        return handler.mock(funcName: "verify(\(verification.id))", args: verification.args)
    }
}
