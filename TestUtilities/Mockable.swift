// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public protocol Mockable {
    associatedtype MockedType
    
    var handler: MockHandler<MockedType> { get }
    
    init(handler: MockHandler<MockedType>)
    init(handlerForBuilder: any MockFunctionHandler)
}

public extension Mockable {
    static func create<M: Mockable>(using erasedDependencies: Any?) -> M {
        let handler: MockHandler<M.MockedType> = MockHandler(
            dummyProvider: { builderHandler in
                return M(handlerForBuilder: builderHandler) as! M.MockedType
            },
            using: erasedDependencies
        )
        
        return M(handler: handler)
    }

    func when<R>(_ callBlock: @escaping (inout MockedType) async throws -> R) -> MockFunctionBuilder<MockedType, R> {
        return handler.createBuilder(for: callBlock)
    }
    
    func removeMocksFor<R>(_ callBlock: @escaping (inout MockedType) async throws -> R) async {
        await handler.removeStubs(for: callBlock)
    }
}
