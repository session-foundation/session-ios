// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import UIKit.UIImage
import SessionUtilitiesKit
import TestUtilities

final class MockFileHandle: FileHandleType, Mockable {
    public let handler: MockHandler<FileHandleType>
    
    required init(handler: MockHandler<FileHandleType>) {
        self.handler = handler
    }
    
    required init(handlerForBuilder: any MockFunctionHandler) {
        self.handler = MockHandler(forwardingHandler: handlerForBuilder)
    }
    
    func readToEnd() throws -> Data? {
        return try handler.mockThrowing()
    }
    
    func read(upToCount count: Int) throws -> Data? {
        return try handler.mockThrowing(args: [count])
    }
    
    func offset() throws -> UInt64 {
        return try handler.mockThrowing()
    }
    
    func seekToEnd() throws -> UInt64 {
        return try handler.mockThrowing()
    }
    
    func write<T>(contentsOf data: T) throws where T : DataProtocol {
        return try handler.mockThrowing(generics: [T.self], args: [data])
    }
    
    func close() throws {
        return try handler.mockThrowing()
    }
}
