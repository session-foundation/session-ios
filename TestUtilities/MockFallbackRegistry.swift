// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public final class MockFallbackRegistry {
    internal static let shared: MockFallbackRegistry = MockFallbackRegistry()
    private var fallbacks: [ObjectIdentifier: () -> Any] = [:]
    private let lock: NSLock = NSLock()
    
    private init() {}
    
    // MARK: - Public Functions
    
    public static func register<T>(for type: T.Type, provider: @escaping () -> T) {
        shared.registerFallback(for: type, provider: provider)
    }
    
    // MARK: - Internal Functions

    internal func registerFallback<T>(for type: T.Type, provider: @escaping () -> T) {
        lock.lock()
        defer { lock.unlock() }
        
        let typeId: ObjectIdentifier = ObjectIdentifier(T.self)
        fallbacks[typeId] = provider
    }
    
    internal func makeFallback<T>(for type: T.Type) -> T? {
        lock.lock()
        defer { lock.unlock() }
        
        let typeId: ObjectIdentifier = ObjectIdentifier(T.self)
        
        if let provider = fallbacks[typeId], let value: T = provider() as? T {
            return value
        }
        
        if let mockedType = T.self as? any Mocked.Type, let value = mockedType.mock as? T {
            return value
        }
        
        return nil
    }
}
