// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Quick

@testable import SessionUtilitiesKit

public class TestDependencies: Dependencies {
    private var singletonInstances: [String: Any] = [:]
    private var cacheInstances: [String: MutableCacheType] = [:]
    private var defaultsInstances: [String: (any UserDefaultsType)] = [:]
    private var mockedValues: [Int: Any] = [:]
    
    // MARK: - Subscript Access
    
    override public subscript<S>(singleton singleton: SingletonConfig<S>) -> S {
        return getValueSettingIfNull(singleton: singleton, &singletonInstances)
    }
    
    public subscript<S>(singleton singleton: SingletonConfig<S>) -> S? {
        get { return (singletonInstances[singleton.identifier] as? S) }
        set { singletonInstances[singleton.identifier] = newValue }
    }
    
    override public subscript<M, I>(cache cache: CacheConfig<M, I>) -> I {
        return getValueSettingIfNull(cache: cache, &cacheInstances)
    }
    
    public subscript<M, I>(cache cache: CacheConfig<M, I>) -> M? {
        get { return (cacheInstances[cache.identifier] as? M) }
        set { cacheInstances[cache.identifier] = newValue.map { cache.mutableInstance($0) } }
    }
    
    override public subscript(defaults defaults: UserDefaultsConfig) -> UserDefaultsType {
        return getValueSettingIfNull(defaults: defaults, &defaultsInstances)
    }
    
    public subscript(defaults defaults: UserDefaultsConfig) -> UserDefaultsType? {
        get { return defaultsInstances[defaults.identifier] }
        set { defaultsInstances[defaults.identifier] = newValue }
    }
    
    // MARK: - Timing and Async Handling

    private var _dateNow: Atomic<Date?> = Atomic(nil)
    override public var dateNow: Date {
        get { (_dateNow.wrappedValue ?? Date()) }
        set { _dateNow.mutate { $0 = newValue } }
    }

    private var _fixedTime: Atomic<Int?> = Atomic(nil)
    override public var fixedTime: Int {
        get { (_fixedTime.wrappedValue ?? 0) }
        set { _fixedTime.mutate { $0 = newValue } }
    }
    
    public var _forceSynchronous: Bool = false
    override public var forceSynchronous: Bool {
        get { _forceSynchronous }
        set { _forceSynchronous = newValue }
    }
    
    private var asyncExecutions: [Int: [() -> Void]] = [:]

    // MARK: - Initialization
    
    public init(initialState: ((TestDependencies) -> ())? = nil) {
        super.init()
        
        initialState?(self)
    }
    
    // MARK: - Functions
    
    public override func mockableValue<T>(key: String? = nil, _ defaultValue: T) -> T {
        let key: Int = (key?.hashValue ?? ObjectIdentifier(T.self).hashValue)

        return ((mockedValues[key] as? T) ?? defaultValue)
    }
    
    public func setMockableValue<T>(key: String? = nil, _ value: T) {
        let key: Int = (key?.hashValue ?? ObjectIdentifier(T.self).hashValue)
        
        return mockedValues[key] = value
    }
    
    override public func async(at timestamp: TimeInterval, closure: @escaping () -> Void) {
        asyncExecutions.append(closure, toArrayOn: Int(ceil(timestamp)))
    }
    
    @discardableResult override public func mutate<M, I, R>(
        cache: CacheConfig<M, I>,
        _ mutation: (inout M) -> R
    ) -> R {
        var value: M = ((cacheInstances[cache.identifier] as? M) ?? cache.createInstance(self))
        return mutation(&value)
    }
    
    @discardableResult override public func mutate<M, I, R>(
        cache: CacheConfig<M, I>,
        _ mutation: (inout M) throws -> R
    ) throws -> R {
        var value: M = ((cacheInstances[cache.identifier] as? M) ?? cache.createInstance(self))
        return try mutation(&value)
    }
    
    public func stepForwardInTime() {
        let targetTime: Int = ((_fixedTime.wrappedValue ?? 0) + 1)
        _fixedTime.mutate { $0 = targetTime }
        
        if let currentDate: Date = _dateNow.wrappedValue {
            _dateNow.mutate { $0 = Date(timeIntervalSince1970: currentDate.timeIntervalSince1970 + 1) }
        }
        
        // Run and clear any executions which should run at the target time
        let targetKeys: [Int] = asyncExecutions.keys
            .filter { $0 <= targetTime }
        targetKeys.forEach { key in
            asyncExecutions[key]?.forEach { $0() }
            asyncExecutions[key] = nil
        }
    }
    
    // MARK: - Random Access Functions
    
    public override func randomElement<T: Collection>(_ collection: T) -> T.Element? {
        return collection.first
    }
    
    /// `Set<T>` is unsorted so we need a deterministic method to retrieve the same value each time
    public override func randomElement<T>(_ elements: Set<T>) -> T? {
        return Array(elements)
            .sorted { lhs, rhs -> Bool in lhs.hashValue < rhs.hashValue }
            .first
    }
    
    /// `Set<T>` is unsorted so we need a deterministic method to retrieve the same value each time
    public override func popRandomElement<T>(_ elements: inout Set<T>) -> T? {
        let result: T? = Array(elements)
            .sorted { lhs, rhs -> Bool in lhs.hashValue < rhs.hashValue }
            .first
        
        return result.map { elements.remove($0) }
    }
    
    // MARK: - Instance upserting
    
    @discardableResult private func getValueSettingIfNull<S>(
        singleton: SingletonConfig<S>,
        _ store: inout [String: Any]
    ) -> S {
        guard let value: S = (store[singleton.identifier] as? S) else {
            let value: S = singleton.createInstance(self)
            store[singleton.identifier] = value
            return value
        }

        return value
    }
    
    @discardableResult private func getValueSettingIfNull<M, I>(
        cache: CacheConfig<M, I>,
        _ store: inout [String: MutableCacheType]
    ) -> I {
        guard let value: M = (store[cache.identifier] as? M) else {
            let value: M = cache.createInstance(self)
            let mutableInstance: MutableCacheType = cache.mutableInstance(value)
            store[cache.identifier] = mutableInstance
            return cache.immutableInstance(value)
        }
        
        return cache.immutableInstance(value)
    }
    
    @discardableResult private func getValueSettingIfNull(
        defaults: UserDefaultsConfig,
        _ store: inout [String: (any UserDefaultsType)]
    ) -> UserDefaultsType {
        guard let value: UserDefaultsType = store[defaults.identifier] else {
            let value: UserDefaultsType = defaults.createInstance(self)
            store[defaults.identifier] = value
            return value
        }

        return value
    }
}

// MARK: - TestState Convenience

internal extension TestState {
    init<M, I>(
        wrappedValue: @escaping @autoclosure () -> T?,
        cache: CacheConfig<M, I>,
        in dependencies: @escaping @autoclosure () -> TestDependencies?
    ) where T: MutableCacheType {
        self.init(wrappedValue: {
            let value: T? = wrappedValue()
            dependencies()![cache: cache] = (value as! M)
            
            return value
        }())
    }
    
    init<S>(
        wrappedValue: @escaping @autoclosure () -> T?,
        singleton: SingletonConfig<S>,
        in dependencies: @escaping @autoclosure () -> TestDependencies?
    ) {
        self.init(wrappedValue: {
            let value: T? = wrappedValue()
            dependencies()![singleton: singleton] = (value as! S)
            
            return value
        }())
    }
    
    init(
        wrappedValue: @escaping @autoclosure () -> T?,
        defaults: UserDefaultsConfig,
        in dependencies: @escaping @autoclosure () -> TestDependencies?
    ) where T: UserDefaultsType {
        self.init(wrappedValue: {
            let value: T? = wrappedValue()
            dependencies()![defaults: defaults] = value
            
            return value
        }())
    }
}
