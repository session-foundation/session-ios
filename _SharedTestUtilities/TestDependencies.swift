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
    @ThreadSafeObject private var featureValues: [String: Any] = [:]
    @ThreadSafeObject private var otherInstances: [ObjectIdentifier: Any] = [:]
    
    // MARK: - Subscript Access
    
    override public subscript<S>(singleton singleton: SingletonConfig<S>) -> S {
        guard let value: S = (singletonInstances[singleton.identifier] as? S) else {
            let key: Dependencies.Key = Dependencies.Key.Variant.singleton.key(singleton.identifier)
            let value: S = singleton.createInstance(self, key)
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
            let key: Dependencies.Key = Dependencies.Key.Variant.cache.key(cache.identifier)
            let value: M = cache.createInstance(self, key)
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
            let key: Dependencies.Key = Dependencies.Key.Variant.userDefaults.key(defaults.identifier)
            let value: UserDefaultsType = defaults.createInstance(self, key)
            _defaultsInstances.performUpdate { $0.setting(defaults.identifier, value) }
            return value
        }

        return value
    }
    
    override public subscript<T: FeatureOption>(feature feature: FeatureConfig<T>) -> T {
        guard let value: Feature<T> = (featureInstances[feature.identifier] as? Feature<T>) else {
            let key: Dependencies.Key = Dependencies.Key.Variant.feature.key(feature.identifier)
            let value: Feature<T> = feature.createInstance(self, key)
            _featureInstances.performUpdate { $0.setting(feature.identifier, value) }
            return value.currentValue(in: self)
        }
        
        return value.currentValue(in: self)
    }
    
    public subscript<T: FeatureOption>(feature feature: FeatureConfig<T>) -> T? {
        get { return (featureInstances[feature.identifier] as? T) }
        set {
            if featureInstances[feature.identifier] == nil {
                let key: Dependencies.Key = Dependencies.Key.Variant.feature.key(feature.identifier)
                _featureInstances.performUpdate {
                    $0.setting(feature.identifier, feature.createInstance(self, key))
                }
            }
            
            switch newValue {
                case .none: removeFeatureValue(forKey: feature.identifier)
                case .some(let value): set(feature: feature, to: value)
            }
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
    
    override public func sleep(for interval: DispatchTimeInterval) async throws {
        try await withCheckedThrowingContinuation { continuum in
            let seconds: TimeInterval
            
            switch interval {
                case .seconds(let s): seconds = TimeInterval(s)
                case .milliseconds(let ms): seconds = (TimeInterval(ms) / 1_000)
                case .microseconds(let us): seconds = (TimeInterval(us) / 1_000_000)
                case .nanoseconds(let ns): seconds = (TimeInterval(ns) / 1_000_000_000)
                case .never: seconds = TimeInterval.greatestFiniteMagnitude
                @unknown default: seconds = TimeInterval.greatestFiniteMagnitude
            }
            
            async(at: seconds) {
                continuum.resume()
            }
        }
    }
    
    @ThreadSafeObject private var asyncExecutions: [Int: [() async -> Void]] = [:]
    
    public func useLiveDateNow() {
        _cachedDateNow.set(to: nil)
    }

    // MARK: - Initialization
    
    public init(initialState: ((TestDependencies) -> ())? = nil) {
        super.init()
        
        initialState?(self)
    }
    
    // MARK: - Functions
    
    public func async(at fixedTime: Int, closure: @escaping () async -> Void) {
        async(at: TimeInterval(fixedTime), closure: closure)
    }
    
    public func async(at timestamp: TimeInterval, closure: @escaping () async -> Void) {
        _asyncExecutions.performUpdate { $0.appending(closure, toArrayOn: Int(ceil(timestamp))) }
    }
    
    @discardableResult override public func mutate<M, I, R>(
        cache: CacheConfig<M, I>,
        _ mutation: (M) -> R
    ) -> R {
        let key: Dependencies.Key = Dependencies.Key.Variant.cache.key(cache.identifier)
        let value: M = ((cacheInstances[cache.identifier] as? M) ?? cache.createInstance(self, key))
        let mutableInstance: MutableCacheType = cache.mutableInstance(value)
        _cacheInstances.performUpdate { $0.setting(cache.identifier, mutableInstance) }
        return mutation(value)
    }
    
    @discardableResult override public func mutate<M, I, R>(
        cache: CacheConfig<M, I>,
        _ mutation: (M) throws -> R
    ) throws -> R {
        let key: Dependencies.Key = Dependencies.Key.Variant.cache.key(cache.identifier)
        let value: M = ((cacheInstances[cache.identifier] as? M) ?? cache.createInstance(self, key))
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
    
    public func stepForwardInTime() async {
        let targetTime: Int = ((cachedFixedTime ?? 0) + 1)
        cachedFixedTime = targetTime
        
        if let currentDate: Date = cachedDateNow {
            _cachedDateNow.set(to: Date(timeIntervalSince1970: currentDate.timeIntervalSince1970 + 1))
        }
        
        // Run and clear any executions which should run at the target time
        let closures: [() async -> Void] = _asyncExecutions.performUpdateAndMap { executions in
            let targetKeys: [Int] = executions.keys.filter { $0 <= targetTime }.sorted()
            let result: [() async -> Void] = targetKeys.flatMap { executions[$0] ?? [] }
            let updatedValue: [Int: [() async -> Void]] = executions.filter { key, _ in
                !targetKeys.contains(key)
            }
            
            return (updatedValue, result)
        }
        for closure in closures {
            await closure()
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
    
    public override func warm<S>(singleton: SingletonConfig<S>) {
        /// Only warm the instance if we don't have a custom one (if we have a custom one then it is already "warmed")
        guard _singletonInstances.performMap({ $0[singleton.identifier] }) == nil else { return }
        
        super.warm(singleton: singleton)
    }
    
    public override func warm<M, I>(cache: CacheConfig<M, I>) {
        /// Only warm the instance if we don't have a custom one (if we have a custom one then it is already "warmed")
        guard _cacheInstances.performMap({ $0[cache.identifier] }) == nil else { return }
        
        super.warm(cache: cache)
    }
    
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
    
    public func get<T>(other: ObjectIdentifier) -> T? {
        return _otherInstances.performMap { $0[other] as? T }
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
    
    public func set<T>(other: ObjectIdentifier, to instance: T) {
        (instance as? DependenciesSettable)?.setDependencies(self)
        _otherInstances.performUpdate { $0.setting(other, instance) }
    }
    
    public override func remove<S>(singleton: SingletonConfig<S>) {
        _cacheInstances.performUpdate { $0.setting(singleton.identifier, nil) }
        
        super.remove(singleton: singleton)
    }
    
    public override func remove<M, I>(cache: CacheConfig<M, I>) {
        _cacheInstances.performUpdate { $0.setting(cache.identifier, nil) }
        
        super.remove(cache: cache)
    }
    
    public override func removeAll() {
        _singletonInstances.performUpdate { _ in [:] }
        _cacheInstances.performUpdate { _ in [:] }
        _defaultsInstances.performUpdate { _ in [:] }
        _featureInstances.performUpdate { _ in [:] }
        _featureValues.performUpdate { _ in [:] }
        _otherInstances.performUpdate { _ in [:] }
        
        super.removeAll()
    }
    
    override public func untilInitialised(targetKey: Dependencies.Key) async {
        switch targetKey.variant {
            case .singleton:
                if _singletonInstances.performMap({ $0[targetKey.identifier] != nil }) {
                    return
                }
                
            case .cache:
                if _cacheInstances.performMap({ $0[targetKey.identifier] != nil }) {
                    return
                }
                
            case .userDefaults:
                if _defaultsInstances.performMap({ $0[targetKey.identifier] != nil }) {
                    return
                }
                
            case .feature:
                if _featureInstances.performMap({ $0[targetKey.identifier] != nil }) {
                    return
                }
        }
        
        await super.untilInitialised(targetKey: targetKey)
    }
    
    // MARK: - FeatureStorageType
    
    public override var hardfork: Int { 2 }
    public override var softfork: Int { 11 }
    
    public override func rawFeatureValue(forKey defaultName: String) -> Any? {
        return _featureValues.performMap { $0[defaultName] }
    }
    
    public override func storeFeatureValue(_ value: Any?, forKey defaultName: String) {
        _featureValues.performUpdate { $0.setting(defaultName, value) }
    }
}

// MARK: - DependenciesSettable

protocol DependenciesSettable {
    var dependencies: Dependencies { get }
    
    func setDependencies(_ dependencies: Dependencies?)
}
