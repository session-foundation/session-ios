// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import UIKit.UIImage
import SessionUtilitiesKit
import TestUtilities

final class MockFileHandleFactory: FileHandleFactoryType, Mockable {
    public let handler: MockHandler<FileHandleFactoryType>
    
    required init(handler: MockHandler<FileHandleFactoryType>) {
        self.handler = handler
    }
    
    required init(handlerForBuilder: any MockFunctionHandler) {
        self.handler = MockHandler(forwardingHandler: handlerForBuilder)
    }
    
    func create(forWritingTo url: URL) throws -> FileHandleType {
        return try handler.mockThrowing(args: [url])
    }
    
    func create(forWritingAtPath path: String) -> FileHandleType? {
        return handler.mock(args: [path])
    }
    
    func create(forReadingFrom url: URL) throws -> FileHandleType {
        return try handler.mockThrowing(args: [url])
    }
    
    func create(forReadingAtPath path: String) -> FileHandleType? {
        return handler.mock(args: [path])
    }
}
