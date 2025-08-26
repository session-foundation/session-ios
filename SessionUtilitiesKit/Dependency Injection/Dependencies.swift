// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine

public class Dependencies {
    static let userInfoKey: CodingUserInfoKey = CodingUserInfoKey(rawValue: "session.dependencies.codingOptions")!
    
    /// The `isRTLRetriever` is handled differently from normal dependencies because it's not really treated as such (it's more of
    /// a convenience thing than anything) as such it's held outside of the `DependencyStorage`
    @ThreadSafeObject private static var cachedIsRTLRetriever: (requiresMainThread: Bool, retriever: () -> Bool) = (false, { false })
    @ThreadSafeObject private var storage: DependencyStorage = DependencyStorage()
    
    private typealias DependencyChange = (Dependencies.DependencyStorage.Key, DependencyStorage.Value?)
    private let dependecyChangeStream: AsyncStream<DependencyChange>
    private let dependecyChangeContinuation: AsyncStream<DependencyChange>.Continuation
    
    // MARK: - Subscript Access
    
    public subscript<S>(singleton singleton: SingletonConfig<S>) -> S { getOrCreate(singleton) }
    public subscript<M, I>(cache cache: CacheConfig<M, I>) -> I { getOrCreate(cache).immutable(cache: cache, using: self) }
    public subscript(defaults defaults: UserDefaultsConfig) -> UserDefaultsType { getOrCreate(defaults) }
    public subscript<T: FeatureOption>(feature feature: FeatureConfig<T>) -> T { getOrCreate(feature).currentValue(using: self) }
    
    // MARK: - Global Values, Timing and Async Handling
    
    public static var isRTL: Bool {
        /// Determining `isRTL` might require running on the main thread (it may need to accesses UIKit), if it requires the main thread but
        /// we are on a different thread then just default to `false` to prevent the background thread from potentially lagging and/or crashing
        guard !cachedIsRTLRetriever.requiresMainThread || Thread.isMainThread else { return false }
        
        return cachedIsRTLRetriever.retriever()
    }
    
    public var dateNow: Date { Date() }
    public var fixedTime: Int { 0 }
    public var forceSynchronous: Bool { false }
    
    // MARK: - Initialization
    
    public static func createEmpty() -> Dependencies { return Dependencies(forTesting: false) }
    
    /// This constructor should not be used directly (except for `TestDependencies`), use `Dependencies.createEmpty()` instead
    internal init(forTesting: Bool) {
        let (stream, continuation) = AsyncStream.makeStream(of: DependencyChange.self)
        dependecyChangeStream = stream
        dependecyChangeContinuation = continuation
    }
    
    // MARK: - Functions
    
    public func async(at fixedTime: Int, closure: @escaping () -> Void) {
        async(at: TimeInterval(fixedTime), closure: closure)
    }
    
    public func async(at timestamp: TimeInterval, closure: @escaping () -> Void) {}
    
    @discardableResult public func mutate<M, I, R>(
        cache: CacheConfig<M, I>,
        _ mutation: (M) -> R
    ) -> R {
        return getOrCreate(cache).performMap { erasedValue in
            guard let value: M = (erasedValue as? M) else {
                /// This code path should never happen (and is essentially invalid if it does) but in order to avoid neeing to return
                /// a nullable type or force-casting this is how we need to do things)
                Log.critical("Failed to convert erased cache value for '\(cache.identifier)' to expected type: \(M.self)")
                let fallbackValue: M = cache.createInstance(self)
                return mutation(fallbackValue)
            }
            
            return mutation(value)
        }
    }
    
    @discardableResult public func mutate<M, I, R>(
        cache: CacheConfig<M, I>,
        _ mutation: (M) throws -> R
    ) throws -> R {
        return try getOrCreate(cache).performMap { erasedValue in
            guard let value: M = (erasedValue as? M) else {
                /// This code path should never happen (and is essentially invalid if it does) but in order to avoid neeing to return
                /// a nullable type or force-casting this is how we need to do things)
                Log.critical("Failed to convert erased cache value for '\(cache.identifier)' to expected type: \(M.self)")
                let fallbackValue: M = cache.createInstance(self)
                return try mutation(fallbackValue)
            }
            
            return try mutation(value)
        }
    }
    
    @discardableResult public func mutateAsyncAware<M, I, R>(
        cache: CacheConfig<M, I>,
        _ mutation: (M) -> R
    ) async -> R {
        return mutate(cache: cache, mutation)
    }
    
    @discardableResult public func mutateAsyncAware<M, I, R>(
        cache: CacheConfig<M, I>,
        _ mutation: (M) throws -> R
    ) async throws -> R {
        return try mutate(cache: cache, mutation)
    }
    
    // MARK: - Random
    
    public func randomUUID() -> UUID {
        return UUID()
    }
    
    public func randomElement<T: Collection>(_ collection: T) -> T.Element? {
        return collection.randomElement()
    }
    
    public func randomElement<T>(_ elements: Set<T>) -> T? {
        return elements.randomElement()
    }
    
    public func popRandomElement<T>(_ elements: inout Set<T>) -> T? {
        return elements.popRandomElement()
    }
    
    // MARK: - Instance management
    
    public func warmCache<M, I>(cache: CacheConfig<M, I>) {
        _ = getOrCreate(cache)
    }
    
    public func set<S>(singleton: SingletonConfig<S>, to instance: S) {
        setValue(instance, typedStorage: .singleton(instance), key: singleton.identifier)
    }
    
    public func set<M, I>(cache: CacheConfig<M, I>, to instance: M) {
        let value: ThreadSafeObject<MutableCacheType> = ThreadSafeObject(cache.mutableInstance(instance))
        setValue(value, typedStorage: .cache(value), key: cache.identifier)
    }
    
    public func remove<M, I>(cache: CacheConfig<M, I>) {
        removeValue(cache.identifier, of: .cache)
    }
    
    public static func setIsRTLRetriever(requiresMainThread: Bool, isRTLRetriever: @escaping () -> Bool) {
        _cachedIsRTLRetriever.set(to: (requiresMainThread, isRTLRetriever))
    }
    
    private func waitUntilInitialised(targetKey: Dependencies.DependencyStorage.Key) async throws {
        /// If we already have an instance (which isn't a `NoopDependency`) then no need to observe the stream
        guard !_storage.performMap({ $0.instances[targetKey]?.isNoop == false }) else { return }
        
        for await (key, instance) in dependecyChangeStream {
            /// If the target instance has been set (and isn't a `NoopDependency`) then we can stop waiting (observing the stream)
            if key == targetKey && instance?.isNoop == false {
                break
            }
        }
    }
    
    public func waitUntilInitialised<S>(singleton: SingletonConfig<S>) async throws {
        try await waitUntilInitialised(targetKey: DependencyStorage.Key.Variant.singleton.key(singleton.identifier))
    }
    
    public func waitUntilInitialised<M, I>(cache: CacheConfig<M, I>) async throws {
        try await waitUntilInitialised(targetKey: DependencyStorage.Key.Variant.cache.key(cache.identifier))
    }
}

// MARK: - Cache Management

private extension ThreadSafeObject<MutableCacheType> {
    func immutable<M, I>(cache: CacheConfig<M, I>, using dependencies: Dependencies) -> I {
        return cache.immutableInstance(
            (self.wrappedValue as? M) ??
            cache.createInstance(dependencies)
        )
    }
}

// MARK: - Feature Management

public extension Dependencies {
    func hasSet<T: FeatureOption>(feature: FeatureConfig<T>) -> Bool {
        let key: Dependencies.DependencyStorage.Key = DependencyStorage.Key.Variant.feature
            .key(feature.identifier)
        
        /// Use a `readLock` to check if a value has been set
        guard
            let typedValue: DependencyStorage.Value = _storage.performMap({ $0.instances[key] }),
            let existingValue: Feature<T> = typedValue.value(as: Feature<T>.self)
        else { return false }
        
        return existingValue.hasStoredValue(using: self)
    }
    
    func set<T: FeatureOption>(feature: FeatureConfig<T>, to updatedFeature: T?) {
        let key: Dependencies.DependencyStorage.Key = DependencyStorage.Key.Variant.feature
            .key(feature.identifier)
        let typedValue: DependencyStorage.Value? = _storage.performMap { $0.instances[key] }
        
        /// Update the cached & in-memory values
        let instance: Feature<T> = (
            typedValue?.value(as: Feature<T>.self) ??
            feature.createInstance(self)
        )
        instance.setValue(to: updatedFeature, using: self)
        setValue(instance, typedStorage: .feature(instance), key: feature.identifier)
        
        /// Notify observers
        notifyAsync(events: [
            ObservedEvent(key: .feature(feature), value: updatedFeature),
            ObservedEvent(key: .featureGroup(feature), value: nil)
        ])
    }
    
    func reset<T: FeatureOption>(feature: FeatureConfig<T>) {
        let key: Dependencies.DependencyStorage.Key = DependencyStorage.Key.Variant.feature
            .key(feature.identifier)
        
        /// Reset the cached and in-memory values
        _storage.perform { storage in
            storage.instances[key]?
                .value(as: Feature<T>.self)?
                .setValue(to: nil, using: self)
        }
        removeValue(feature.identifier, of: .feature)
        
        /// Notify observers
        dependecyChangeContinuation.yield((key, nil))
        notifyAsync(events: [
            ObservedEvent(key: .feature(feature), value: nil),
            ObservedEvent(key: .featureGroup(feature), value: nil)
        ])
    }
}

// MARK: - DependenciesError

public enum DependenciesError: Error {
    case missingDependencies
}

// MARK: - Storage Management

private extension Dependencies {
    class DependencyStorage {
        var initializationLocks: [Key: NSLock] = [:]
        var instances: [Key: Value] = [:]
        
        struct Key: Hashable, CustomStringConvertible {
            enum Variant: String {
                case singleton
                case cache
                case userDefaults
                case feature
                
                func key(_ identifier: String) -> Key {
                    return Key(identifier, of: self)
                }
            }
            
            let identifier: String
            let variant: Variant
            var description: String { "\(variant): \(identifier)" }
            
            init(_ identifier: String, of variant: Variant) {
                self.identifier = identifier
                self.variant = variant
            }
        }
        
        enum Value {
            case singleton(Any)
            case cache(ThreadSafeObject<MutableCacheType>)
            case userDefaults(UserDefaultsType)
            case feature(any FeatureType)
            
            var isNoop: Bool {
                switch self {
                    case .singleton(let value): return value is NoopDependency
                    case .userDefaults(let value): return value is NoopDependency
                    case .feature(let value): return value is NoopDependency
                    case .cache(let value): return value.performMap { $0 is NoopDependency }
                }
            }
            
            func distinctKey(for identifier: String) -> Key {
                switch self {
                    case .singleton: return Key(identifier, of: .singleton)
                    case .cache: return Key(identifier, of: .cache)
                    case .userDefaults: return Key(identifier, of: .userDefaults)
                    case .feature: return Key(identifier, of: .feature)
                }
            }
            
            func value<T>(as type: T.Type) -> T? {
                switch self {
                    case .singleton(let value): return value as? T
                    case .cache(let value): return value as? T
                    case .userDefaults(let value): return value as? T
                    case .feature(let value): return value as? T
                }
            }
        }
    }
    
    private func getOrCreate<S>(_ singleton: SingletonConfig<S>) -> S {
        return getOrCreateInstance(
            identifier: singleton.identifier,
            constructor: .singleton { singleton.createInstance(self) }
        )
    }
    
    private func getOrCreate<M, I>(_ cache: CacheConfig<M, I>) -> ThreadSafeObject<MutableCacheType> {
        return getOrCreateInstance(
            identifier: cache.identifier,
            constructor: .cache { ThreadSafeObject(cache.mutableInstance(cache.createInstance(self))) }
        )
    }
    
    private func getOrCreate(_ defaults: UserDefaultsConfig) -> UserDefaultsType {
        return getOrCreateInstance(
            identifier: defaults.identifier,
            constructor: .userDefaults { defaults.createInstance(self) }
        )
    }
    
    private func getOrCreate<T: FeatureOption>(_ feature: FeatureConfig<T>) -> Feature<T> {
        return getOrCreateInstance(
            identifier: feature.identifier,
            constructor: .feature { feature.createInstance(self) }
        )
    }
    
    // MARK: - Instance upserting
    
    /// Retrieves the current instance or, if one doesn't exist, uses the `StorageHelper.Info<Value>` to create a new instance
    /// and store it
    private func getOrCreateInstance<Value>(
        identifier: String,
        constructor: DependencyStorage.Constructor<Value>
    ) -> Value {
        let key: Dependencies.DependencyStorage.Key = constructor.variant.key(identifier)
        
        /// If we already have an instance then just return that (need to get a `writeLock` here because accessing values on a class
        /// isn't thread safe so we need to block during access)
        if let existingValue: Value = _storage.performMap({ $0.instances[key]?.value(as: Value.self) }) {
            return existingValue
        }
        
        /// Otherwise we need to prevent multiple threads initialising **this** dependency, this is done with it's own
        /// separate lock
        let initializationLock: NSLock = _storage.performUpdateAndMap { storage in
            if let existingLock = storage.initializationLocks[key] {
                return (storage, existingLock)
            }
            
            let newLock = NSLock()
            storage.initializationLocks[key] = newLock
            return (storage, newLock)
        }
        
        /// Acquire the `initializationLock`
        initializationLock.lock()
        defer { initializationLock.unlock() }
        
        /// Now that we have acquired the `initializationLock` we need to check if an instance was created on another
        /// thread while we were waiting
        if let existingValue: Value = _storage.performMap({ $0.instances[key]?.value(as: Value.self) }) {
            return existingValue
        }
        
        /// Create an instance of the dependency **outside** of the `storage` lock (to prevent the initialiser of another
        /// dependency from causing a deadlock)
        let instance: (typedStorage: DependencyStorage.Value, value: Value) = constructor.create()
        
        /// Finally we can store the newly created dependency (this will acquire a `storage` lock again
        return setValue(instance.value, typedStorage: instance.typedStorage, key: identifier)
    }
    
    /// Convenience method to store a dependency instance in memory in a thread-safe way
    @discardableResult private func setValue<T>(_ value: T, typedStorage: DependencyStorage.Value, key: String) -> T {
        let finalKey: DependencyStorage.Key = typedStorage.distinctKey(for: key)
        let result: T = _storage.performUpdateAndMap { storage in
            storage.instances[finalKey] = typedStorage
            return (storage, value)
        }
        
        /// We generally _shouldn't_ be setting a dependency to a no-op value so log a warning when we do so
        if typedStorage.isNoop {
            Log.warn("Setting noop dependency for \(key)")
        }
        
        dependecyChangeContinuation.yield((finalKey, typedStorage))
        return result
    }
    
    /// Convenience method to remove a dependency instance from memory in a thread-safe way
    private func removeValue(_ key: String, of variant: DependencyStorage.Key.Variant) {
        let finalKey: DependencyStorage.Key = variant.key(key)
        _storage.performUpdate { storage in
            storage.instances.removeValue(forKey: finalKey)
            return storage
        }
        
        dependecyChangeContinuation.yield((finalKey, nil))
    }
}
 
// MARK: - DSL

private extension Dependencies.DependencyStorage {
    struct Constructor<T> {
        let variant: Key.Variant
        let create: () -> (typedStorage: Dependencies.DependencyStorage.Value, value: T)
        
        static func singleton(_ constructor: @escaping () -> T) -> Constructor<T> {
            return Constructor(variant: .singleton) {
                let instance: T = constructor()
                
                return (.singleton(instance), instance)
            }
        }
        
        static func cache(_ constructor: @escaping () -> T) -> Constructor<T> where T: ThreadSafeObject<MutableCacheType> {
            return Constructor(variant: .cache) {
                let instance: T = constructor()
                
                return (.cache(instance), instance)
            }
        }
        
        static func userDefaults(_ constructor: @escaping () -> T) -> Constructor<T> where T == UserDefaultsType {
            return Constructor(variant: .userDefaults) {
                let instance: T = constructor()
                
                return (.userDefaults(instance), instance)
            }
        }
        
        static func feature(_ constructor: @escaping () -> T) -> Constructor<T> where T: FeatureType {
            return Constructor(variant: .feature) {
                let instance: T = constructor()
                
                return (.feature(instance), instance)
            }
        }
    }
}
