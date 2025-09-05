// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit
import TestUtilities

open class FixtureBase {
    let dependencies: TestDependencies = TestDependencies()
    
    public init() {
        dependencies.dateNow = Date(timeIntervalSince1970: 1234567890)
        dependencies.forceSynchronous = true
    }
    
    public func mock<R, SingletonType>(
        for singleton: SingletonConfig<SingletonType>,
        _ creation: (TestDependencies) -> R
    ) -> R {
        if let existingMock: R = dependencies.get(singleton: singleton) as? R {
            return existingMock
        }
        
        let value: R = creation(dependencies)
        (value as? DependenciesSettable)?.setDependencies(dependencies)
        
        guard let conformingValue: SingletonType = value as? SingletonType else {
            fatalError("Type Mismatch: The mock of type '\(type(of: value))' does not conform to the required protocol '\(SingletonType.self)' for the provided singleton key.")
        }
        
        dependencies.set(singleton: singleton, to: conformingValue)
        return value
    }
    
    public func mock<R, MutableCache, ImmutableCache>(
        cache: CacheConfig<MutableCache, ImmutableCache>,
        _ creation: (TestDependencies) -> R
    ) -> R {
        if let existingMock: R = dependencies.get(cache: cache) as? R {
            return existingMock
        }
        
        let value: R = creation(dependencies)
        (value as? DependenciesSettable)?.setDependencies(dependencies)
        
        guard let conformingValue: MutableCache = value as? MutableCache else {
            fatalError("Type Mismatch: The mock of type '\(type(of: value))' does not conform to the required protocol '\(MutableCache.self)' for the provided singleton key.")
        }
        
        dependencies.set(cache: cache, to: conformingValue)
        return value
    }
    
    public func mock<T: UserDefaultsType>(
        for defaults: UserDefaultsConfig,
        _ creation: (TestDependencies) -> T
    ) -> T {
        if let existingMock: T = dependencies.get(defaults: defaults) {
            return existingMock
        }
        
        let value: T = creation(dependencies)
        (value as? DependenciesSettable)?.setDependencies(dependencies)
        dependencies.set(defaults: defaults, to: value)
        
        return value
    }
    
    // MARK: - No Dependencies Convenience
    
    public func mock<R, SingletonType>(
        for singleton: SingletonConfig<SingletonType>,
        _ creation: () -> R
    ) -> R {
        return mock(for: singleton) { _ in creation() }
    }
    
    public func mock<R, MutableCache, ImmutableCache>(
        cache: CacheConfig<MutableCache, ImmutableCache>,
        _ creation: () -> R
    ) -> R {
        return mock(cache: cache) { _ in creation() }
    }
    
    public func mock<T: UserDefaultsType>(
        for defaults: UserDefaultsConfig,
        _ creation: () -> T
    ) -> T {
        return mock(for: defaults) { _ in creation() }
    }
    
    // MARK: - Mockable Convenience
    
    public func mock<R: Mockable, SingletonType>(for singleton: SingletonConfig<SingletonType>) -> R {
        return mock(for: singleton) { _ in R.create() }
    }
    
    public func mock<R: Mockable, MutableCache, ImmutableCache>(cache: CacheConfig<MutableCache, ImmutableCache>) -> R {
        return mock(cache: cache) { _ in R.create() }
    }
    
    public func mock<T: Mockable & UserDefaultsType>(defaults: UserDefaultsConfig) -> T {
        return mock(for: defaults) { _ in T.create() }
    }
}
