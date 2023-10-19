// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import GRDB

public class Dependencies {
    static let userInfoKey: CodingUserInfoKey = CodingUserInfoKey(rawValue: "io.oxen.dependencies.codingOptions")!
    
    private static var singletonInstances: Atomic<[String: Any]> = Atomic([:])
    private static var cacheInstances: Atomic<[String: Atomic<MutableCacheType>]> = Atomic([:])
    private static var userDefaultsInstances: Atomic<[String: (any UserDefaultsType)]> = Atomic([:])
    
    // MARK: - Subscript Access
    
    public subscript<S>(singleton singleton: SingletonConfig<S>) -> S {
        getValueSettingIfNull(singleton: singleton, &Dependencies.singletonInstances)
    }
    
    public subscript<M, I>(cache cache: CacheConfig<M, I>) -> I {
        getValueSettingIfNull(cache: cache, &Dependencies.cacheInstances)
    }
    
    public subscript(defaults defaults: UserDefaultsConfig) -> UserDefaultsType {
        getValueSettingIfNull(defaults: defaults, &Dependencies.userDefaultsInstances)
    }
    
    // MARK: - Timing and Async Handling
    
    public var dateNow: Date { Date() }
    public var fixedTime: Int { 0 }
    public var forceSynchronous: Bool { false }
    
    // MARK: - Initialization
    
    public init() {}
    
    // MARK: - Functions
    
    public func mockableValue<T>(key: String? = nil, _ defaultValue: T) -> T { defaultValue }
    
    public func async(at fixedTime: Int, closure: @escaping () -> Void) {
        async(at: TimeInterval(fixedTime), closure: closure)
    }
    
    public func async(at timestamp: TimeInterval, closure: @escaping () -> Void) {}
    
    @discardableResult public func mutate<M, I, R>(
        cache: CacheConfig<M, I>,
        _ mutation: (inout M) -> R
    ) -> R {
        /// The cast from `Atomic<MutableCacheType>` to `Atomic<M>` always fails so we need to do some
        /// stuffing around to ensure we have the right types - since we call `createInstance` multiple times in
        /// the below code we first call `getValueSettingIfNull` to ensure we have a proper instance stored
        /// in `Dependencies.cacheInstances` so that we can be reliably certail we aren't accessing some
        /// random instance that will go out of memory as soon as the mutation is completed
        getValueSettingIfNull(cache: cache, &Dependencies.cacheInstances)
        let cacheWrapper: Atomic<MutableCacheType> = (
            Dependencies.cacheInstances.wrappedValue[cache.identifier] ??
            Atomic(cache.mutableInstance(cache.createInstance(self)))  // Should never be called
        )
        
        return cacheWrapper.mutate { erasedValue in
            var value: M = ((erasedValue as? M) ?? cache.createInstance(self))
            return mutation(&value)
        }
    }
    
    @discardableResult public func mutate<M, I, R>(
        cache: CacheConfig<M, I>,
        _ mutation: (inout M) throws -> R
    ) throws -> R {
        /// The cast from `Atomic<MutableCacheType>` to `Atomic<M>` always fails so we need to do some
        /// stuffing around to ensure we have the right types - since we call `createInstance` multiple times in
        /// the below code we first call `getValueSettingIfNull` to ensure we have a proper instance stored
        /// in `Dependencies.cacheInstances` so that we can be reliably certail we aren't accessing some
        /// random instance that will go out of memory as soon as the mutation is completed
        getValueSettingIfNull(cache: cache, &Dependencies.cacheInstances)
        
        let cacheWrapper: Atomic<MutableCacheType> = (
            Dependencies.cacheInstances.wrappedValue[cache.identifier] ??
            Atomic(cache.mutableInstance(cache.createInstance(self)))  // Should never be called
        )
        
        return try cacheWrapper.mutate { erasedValue in
            var value: M = ((erasedValue as? M) ?? cache.createInstance(self))
            return try mutation(&value)
        }
    }
    
    // MARK: - Random Access Functions
    
    public func randomElement<T: Collection>(_ collection: T) -> T.Element? {
        return collection.randomElement()
    }
    
    public func randomElement<T>(_ elements: Set<T>) -> T? {
        return elements.randomElement()
    }
    
    public func popRandomElement<T>(_ elements: inout Set<T>) -> T? {
        return elements.popRandomElement()
    }

    // MARK: - Instance upserting
    
    @discardableResult private func getValueSettingIfNull<S>(
        singleton: SingletonConfig<S>,
        _ store: inout Atomic<[String: Any]>
    ) -> S {
        guard let value: S = (store.wrappedValue[singleton.identifier] as? S) else {
            let value: S = singleton.createInstance(self)
            store.mutate { $0[singleton.identifier] = value }
            return value
        }

        return value
    }
    
    @discardableResult private func getValueSettingIfNull<M, I>(
        cache: CacheConfig<M, I>,
        _ store: inout Atomic<[String: Atomic<MutableCacheType>]>
    ) -> I {
        guard let value: M = (store.wrappedValue[cache.identifier]?.wrappedValue as? M) else {
            let value: M = cache.createInstance(self)
            let mutableInstance: MutableCacheType = cache.mutableInstance(value)
            store.mutate { $0[cache.identifier] = Atomic(mutableInstance) }
            return cache.immutableInstance(value)
        }
        
        return cache.immutableInstance(value)
    }
    
    @discardableResult private func getValueSettingIfNull(
        defaults: UserDefaultsConfig,
        _ store: inout Atomic<[String: UserDefaultsType]>
    ) -> UserDefaultsType {
        guard let value: UserDefaultsType = store.wrappedValue[defaults.identifier] else {
            let value: UserDefaultsType = defaults.createInstance(self)
            store.mutate { $0[defaults.identifier] = value }
            return value
        }
        
        return value
    }
}

// MARK: - Storage Setting Convenience

public extension Dependencies {
    subscript(singleton singleton: SingletonConfig<Storage>, key key: Setting.BoolKey) -> Bool {
        return self[singleton: singleton]
            .read { db in db[key] }
            .defaulting(to: false)  // Default to false if it doesn't exist
    }
    
    subscript(singleton singleton: SingletonConfig<Storage>, key key: Setting.DoubleKey) -> Double? {
        return self[singleton: singleton].read { db in db[key] }
    }
    
    subscript(singleton singleton: SingletonConfig<Storage>, key key: Setting.IntKey) -> Int? {
        return self[singleton: singleton].read { db in db[key] }
    }
    
    subscript(singleton singleton: SingletonConfig<Storage>, key key: Setting.StringKey) -> String? {
        return self[singleton: singleton].read { db in db[key] }
    }
    
    subscript(singleton singleton: SingletonConfig<Storage>, key key: Setting.DateKey) -> Date? {
        return self[singleton: singleton].read { db in db[key] }
    }
    
    subscript<T: EnumIntSetting>(singleton singleton: SingletonConfig<Storage>, key key: Setting.EnumKey) -> T? {
        return self[singleton: singleton].read { db in db[key] }
    }
    
    subscript<T: EnumStringSetting>(singleton singleton: SingletonConfig<Storage>, key key: Setting.EnumKey) -> T? {
        return self[singleton: singleton].read { db in db[key] }
    }
}

// MARK: - UserDefaults Convenience

public extension Dependencies {
    subscript(defaults defaults: UserDefaultsConfig, key key: UserDefaults.BoolKey) -> Bool {
        get { return self[defaults: defaults].bool(forKey: key.rawValue) }
        set { self[defaults: defaults].set(newValue, forKey: key.rawValue) }
    }

    subscript(defaults defaults: UserDefaultsConfig, key key: UserDefaults.DateKey) -> Date? {
        get { return self[defaults: defaults].object(forKey: key.rawValue) as? Date }
        set { self[defaults: defaults].set(newValue, forKey: key.rawValue) }
    }
    
    subscript(defaults defaults: UserDefaultsConfig, key key: UserDefaults.DoubleKey) -> Double {
        get { return self[defaults: defaults].double(forKey: key.rawValue) }
        set { self[defaults: defaults].set(newValue, forKey: key.rawValue) }
    }

    subscript(defaults defaults: UserDefaultsConfig, key key: UserDefaults.IntKey) -> Int {
        get { return self[defaults: defaults].integer(forKey: key.rawValue) }
        set { self[defaults: defaults].set(newValue, forKey: key.rawValue) }
    }
    
    subscript(defaults defaults: UserDefaultsConfig, key key: UserDefaults.StringKey) -> String? {
        get { return self[defaults: defaults].string(forKey: key.rawValue) }
        set { self[defaults: defaults].set(newValue, forKey: key.rawValue) }
    }
}
