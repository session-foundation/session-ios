// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit
import TestUtilities

class MockUserDefaults: UserDefaultsType, Mockable {
    public var handler: MockHandler<UserDefaultsType>
    
    required init(handler: MockHandler<UserDefaultsType>) {
        self.handler = handler
    }
    
    required init(handlerForBuilder: any MockFunctionHandler) {
        self.handler = MockHandler(forwardingHandler: handlerForBuilder)
    }
    
    var allKeys: [String] { handler.mock() }
    
    func object(forKey defaultName: String) -> Any? { return handler.mock(args: [defaultName]) }
    func string(forKey defaultName: String) -> String? { return handler.mock(args: [defaultName]) }
    func array(forKey defaultName: String) -> [Any]? { return handler.mock(args: [defaultName]) }
    func dictionary(forKey defaultName: String) -> [String: Any]? { return handler.mock(args: [defaultName]) }
    func data(forKey defaultName: String) -> Data? { return handler.mock(args: [defaultName]) }
    func stringArray(forKey defaultName: String) -> [String]? { return handler.mock(args: [defaultName]) }
    func integer(forKey defaultName: String) -> Int { return (handler.mock(args: [defaultName]) ?? 0) }
    func float(forKey defaultName: String) -> Float { return (handler.mock(args: [defaultName]) ?? 0) }
    func double(forKey defaultName: String) -> Double { return (handler.mock(args: [defaultName]) ?? 0) }
    func bool(forKey defaultName: String) -> Bool { return (handler.mock(args: [defaultName]) ?? false) }
    func url(forKey defaultName: String) -> URL? { return handler.mock(args: [defaultName]) }

    func set(_ value: Any?, forKey defaultName: String) { handler.mockNoReturn(args: [value, defaultName]) }
    func set(_ value: Int, forKey defaultName: String) { handler.mockNoReturn(args: [value, defaultName]) }
    func set(_ value: Float, forKey defaultName: String) { handler.mockNoReturn(args: [value, defaultName]) }
    func set(_ value: Double, forKey defaultName: String) { handler.mockNoReturn(args: [value, defaultName]) }
    func set(_ value: Bool, forKey defaultName: String) { handler.mockNoReturn(args: [value, defaultName]) }
    func set(_ url: URL?, forKey defaultName: String) { handler.mockNoReturn(args: [url, defaultName]) }
    
    func removeObject(forKey defaultName: String) {
        handler.mockNoReturn(args: [defaultName])
    }
    
    func removeAll() { handler.mockNoReturn() }
}

extension MockUserDefaults {
    func defaultInitialSetup() async throws {
        try await self.when { $0.set(anyAny(), forKey: .any) }.thenReturn(())
        try await self.when { $0.set(Int.any, forKey: .any) }.thenReturn(())
        try await self.when { $0.set(Float.any, forKey: .any) }.thenReturn(())
        try await self.when { $0.set(Double.any, forKey: .any) }.thenReturn(())
        try await self.when { $0.set(Bool.any, forKey: .any) }.thenReturn(())
        try await self.when { $0.set(URL.any, forKey: .any) }.thenReturn(())
    }
}
