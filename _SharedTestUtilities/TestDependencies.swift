// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import _Concurrency
import Quick
import TestUtilities

@testable import SessionUtilitiesKit

public class TestDependencies: Dependencies {
    @ThreadSafeObject private var singletonInstances: [String: Any] = [:]
    @ThreadSafeObject private var cacheInstances: [String: MutableCacheType] = [:]
    @ThreadSafeObject private var defaultsInstances: [String: (any UserDefaultsType)] = [:]
    @ThreadSafeObject private var featureInstances: [String: (any FeatureType)] = [:]
    
    // MARK: - Subscript Access
    
    override public subscript<S>(singleton singleton: SingletonConfig<S>) -> S {
        guard let value: S = (singletonInstances[singleton.identifier] as? S) else {
            let value: S = singleton.createInstance(self)
            _singletonInstances.performUpdate { $0.setting(singleton.identifier, value) }
            return value
        }

        return value
    }
    
    public subscript<S>(singleton singleton: SingletonConfig<S>) -> S? {
        get { return (singletonInstances[singleton.identifier] as? S) }
        set { _singletonInstances.performUpdate { $0.setting(singleton.identifier, newValue) } }
    }
    
    override public subscript<M, I>(cache cache: CacheConfig<M, I>) -> I {
        guard let value: M = (cacheInstances[cache.identifier] as? M) else {
            let value: M = cache.createInstance(self)
            let mutableInstance: MutableCacheType = cache.mutableInstance(value)
            _cacheInstances.performUpdate { $0.setting(cache.identifier, mutableInstance) }
            return cache.immutableInstance(value)
        }
        
        return cache.immutableInstance(value)
    }
    
    public subscript<M, I>(cache cache: CacheConfig<M, I>) -> M? {
        get { return (cacheInstances[cache.identifier] as? M) }
        set { _cacheInstances.performUpdate { $0.setting(cache.identifier, newValue.map { cache.mutableInstance($0) }) } }
    }
    
    override public subscript(defaults defaults: UserDefaultsConfig) -> UserDefaultsType {
        guard let value: UserDefaultsType = defaultsInstances[defaults.identifier] else {
            let value: UserDefaultsType = defaults.createInstance(self)
            _defaultsInstances.performUpdate { $0.setting(defaults.identifier, value) }
            return value
        }

        return value
    }
    
    override public subscript<T: FeatureOption>(feature feature: FeatureConfig<T>) -> T {
        guard let value: Feature<T> = (featureInstances[feature.identifier] as? Feature<T>) else {
            let value: Feature<T> = feature.createInstance(self)
            _featureInstances.performUpdate { $0.setting(feature.identifier, value) }
            return value.currentValue(using: self)
        }
        
        return value.currentValue(using: self)
    }
    
    public subscript<T: FeatureOption>(feature feature: FeatureConfig<T>) -> T? {
        get { return (featureInstances[feature.identifier] as? T) }
        set {
            if featureInstances[feature.identifier] == nil {
                _featureInstances.performUpdate { $0.setting(feature.identifier, feature.createInstance(self)) }
            }
            
            set(feature: feature, to: newValue)
        }
    }
    
    public subscript(defaults defaults: UserDefaultsConfig) -> UserDefaultsType? {
        get { return defaultsInstances[defaults.identifier] }
        set { _defaultsInstances.performUpdate { $0.setting(defaults.identifier, newValue) } }
    }
    
    // MARK: - Timing and Async Handling

    @ThreadSafeObject private var cachedDateNow: Date? = nil
    override public var dateNow: Date {
        get { (cachedDateNow ?? Date()) }
        set { _cachedDateNow.set(to: newValue) }
    }

    @ThreadSafe private var cachedFixedTime: Int? = nil
    override public var fixedTime: Int {
        get { (cachedFixedTime ?? 0) }
        set { cachedFixedTime = newValue }
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
    
    override public func async(at timestamp: TimeInterval, closure: @escaping () -> Void) {
        asyncExecutions.append(closure, toArrayOn: Int(ceil(timestamp)))
    }
    
    @discardableResult override public func mutate<M, I, R>(
        cache: CacheConfig<M, I>,
        _ mutation: (M) -> R
    ) -> R {
        let value: M = ((cacheInstances[cache.identifier] as? M) ?? cache.createInstance(self))
        let mutableInstance: MutableCacheType = cache.mutableInstance(value)
        _cacheInstances.performUpdate { $0.setting(cache.identifier, mutableInstance) }
        return mutation(value)
    }
    
    @discardableResult override public func mutate<M, I, R>(
        cache: CacheConfig<M, I>,
        _ mutation: (M) throws -> R
    ) throws -> R {
        let value: M = ((cacheInstances[cache.identifier] as? M) ?? cache.createInstance(self))
        let mutableInstance: MutableCacheType = cache.mutableInstance(value)
        _cacheInstances.performUpdate { $0.setting(cache.identifier, mutableInstance) }
        return try mutation(value)
    }
    
    @discardableResult override public func mutateAsyncAware<M, I, R>(
        cache: CacheConfig<M, I>,
        _ mutation: (M) -> R
    ) async -> R {
        guard forceSynchronous else {
            return mutate(cache: cache, mutation)
        }
        
        return await MainActor.run { mutate(cache: cache, mutation) }
    }
    
    @discardableResult override public func mutateAsyncAware<M, I, R>(
        cache: CacheConfig<M, I>,
        _ mutation: (M) throws -> R
    ) async throws -> R {
        guard forceSynchronous else {
            return try mutate(cache: cache, mutation)
        }
        
        return try await MainActor.run { try mutate(cache: cache, mutation) }
    }
    
    public func stepForwardInTime() {
        let targetTime: Int = ((cachedFixedTime ?? 0) + 1)
        cachedFixedTime = targetTime
        
        if let currentDate: Date = cachedDateNow {
            _cachedDateNow.set(to: Date(timeIntervalSince1970: currentDate.timeIntervalSince1970 + 1))
        }
        
        // Run and clear any executions which should run at the target time
        let targetKeys: [Int] = asyncExecutions.keys
            .filter { $0 <= targetTime }
        targetKeys.forEach { key in
            asyncExecutions[key]?.forEach { $0() }
            asyncExecutions[key] = nil
        }
    }
    
    // MARK: - Random
    
    public var uuid: UUID? = nil
    public override func randomUUID() -> UUID {
        return (uuid ?? UUID())
    }
    
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
    
    // MARK: - Instance replacing
    
    public func get<S>(singleton: SingletonConfig<S>) -> S? {
        return _singletonInstances.performMap { $0[singleton.identifier] as? S }
    }
    
    public func get<M, I>(cache: CacheConfig<M, I>) -> M? {
        return _cacheInstances.performMap { $0[cache.identifier] as? M }
    }
    
    public func get<T: UserDefaultsType>(defaults: UserDefaultsConfig) -> T? {
        return _defaultsInstances.performMap { $0[defaults.identifier] as? T }
    }
    
    public func get<T: FeatureOption>(feature: FeatureConfig<T>) -> T? {
        return _featureInstances.performMap { $0[feature.identifier] as? T }
    }
    
    public override func set<S>(singleton: SingletonConfig<S>, to instance: S) {
        (instance as? DependenciesSettable)?.setDependencies(self)
        _singletonInstances.performUpdate { $0.setting(singleton.identifier, instance) }
    }
    
    public override func set<M, I>(cache: CacheConfig<M, I>, to instance: M) {
        (instance as? DependenciesSettable)?.setDependencies(self)
        _cacheInstances.performUpdate { $0.setting(cache.identifier, cache.mutableInstance(instance)) }
    }
    
    public func set<T: UserDefaultsType>(defaults: UserDefaultsConfig, to instance: T) {
        (instance as? DependenciesSettable)?.setDependencies(self)
        _defaultsInstances.performUpdate { $0.setting(defaults.identifier, instance) }
    }
    
    public func set<T: FeatureOption>(feature: FeatureConfig<T>, to instance: Feature<T>) {
        (instance as? DependenciesSettable)?.setDependencies(self)
        _featureInstances.performUpdate { $0.setting(feature.identifier, instance) }
    }
    
    public override func remove<M, I>(cache: CacheConfig<M, I>) {
        _cacheInstances.performUpdate { $0.setting(cache.identifier, nil) }
    }
}

// MARK: - DependenciesSettable

protocol DependenciesSettable {
    var dependencies: Dependencies { get }
    
    func setDependencies(_ dependencies: Dependencies?)
}

// MARK: - TestState Convenience

internal extension TestState {
    init<S>(
        wrappedValue: @escaping @autoclosure () -> T?,
        singleton: SingletonConfig<S>,
        in dependenciesRetriever: @escaping @autoclosure () -> TestDependencies?
    ) {
        self.init(wrappedValue: {
            let dependencies: TestDependencies? = dependenciesRetriever()
            let value: T? = wrappedValue()
            (value as? DependenciesSettable)?.setDependencies(dependencies)
            dependencies?[singleton: singleton] = (value as! S)
            (value as? (any InitialSetupable))?.performInitialSetup()
            
            return value
        }())
    }
    
    init(
        wrappedValue: @escaping @autoclosure () -> T?,
        defaults: UserDefaultsConfig,
        in dependenciesRetriever: @escaping @autoclosure () -> TestDependencies?
    ) where T: UserDefaultsType {
        self.init(wrappedValue: {
            let dependencies: TestDependencies? = dependenciesRetriever()
            let value: T? = wrappedValue()
            (value as? DependenciesSettable)?.setDependencies(dependencies)
            dependencies?[defaults: defaults] = value
            (value as? (any InitialSetupable))?.performInitialSetup()
            
            return value
        }())
    }
}
