// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

public class Dependencies {
    static let userInfoKey: CodingUserInfoKey = CodingUserInfoKey(rawValue: "io.oxen.dependencies.codingOptions")!
    
    private static var singletonInstances: Atomic<[Int: Any]> = Atomic([:])
    private static var cacheInstances: Atomic<[Int: MutableCacheType]> = Atomic([:])
    private static var userDefaultsInstances: Atomic<[Int: (any UserDefaultsType)]> = Atomic([:])
    
    // MARK: - Subscript Access
    
    public subscript<S>(singleton singleton: SingletonInfo.Config<S>) -> S {
        getValueSettingIfNull(singleton: singleton, &Dependencies.singletonInstances)
    }
    
    public subscript<M, I>(cache cache: CacheInfo.Config<M, I>) -> I {
        getValueSettingIfNull(cache: cache, &Dependencies.cacheInstances)
    }
    
    public subscript(defaults defaults: UserDefaultsInfo.Config) -> UserDefaultsType {
        getValueSettingIfNull(defaults: defaults, &Dependencies.userDefaultsInstances)
    }
    
    // MARK: - Timing and Async Handling
    
    public var dateNow: Date { Date() }
    public var fixedTime: Int { 0 }
    
    public var forceSynchronous: Bool = false
    public var asyncExecutions: [Int: [() -> Void]] = [:]
    
    // MARK: - Initialization
    
    public init() {}
    
    // MARK: - Functions
    
    @discardableResult public func mutate<M, I, R>(
        cache: CacheInfo.Config<M, I>,
        _ mutation: (inout M) -> R
    ) -> R {
        return Dependencies.cacheInstances.mutate { caches in
            var value: M = ((caches[cache.key] as? M) ?? cache.createInstance(self))
            return mutation(&value)
        }
    }
    
    @discardableResult public func mutate<M, I, R>(
        cache: CacheInfo.Config<M, I>,
        _ mutation: (inout M) throws -> R
    ) throws -> R {
        return try Dependencies.cacheInstances.mutate { caches in
            var value: M = ((caches[cache.key] as? M) ?? cache.createInstance(self))
            return try mutation(&value)
        }
    }

    // MARK: - Instance upserting
    
    @discardableResult private func getValueSettingIfNull<S>(
        singleton: SingletonInfo.Config<S>,
        _ store: inout Atomic<[Int: Any]>
    ) -> S {
        guard let value: S = (store.wrappedValue[singleton.key] as? S) else {
            let value: S = singleton.createInstance(self)
            store.mutate { $0[singleton.key] = value }
            return value
        }

        return value
    }
    
    @discardableResult private func getValueSettingIfNull<M, I>(
        cache: CacheInfo.Config<M, I>,
        _ store: inout Atomic<[Int: MutableCacheType]>
    ) -> I {
        guard let value: M = (store.wrappedValue[cache.key] as? M) else {
            let value: M = cache.createInstance(self)
            let mutableInstance: MutableCacheType = cache.mutableInstance(value)
            store.mutate { $0[cache.key] = mutableInstance }
            return cache.immutableInstance(value)
        }
        
        return cache.immutableInstance(value)
    }
    
    @discardableResult private func getValueSettingIfNull(
        defaults: UserDefaultsInfo.Config,
        _ store: inout Atomic<[Int: UserDefaultsType]>
    ) -> UserDefaultsType {
        guard let value: UserDefaultsType = store.wrappedValue[defaults.key] else {
            let value: UserDefaultsType = defaults.createInstance(self)
            store.mutate { $0[defaults.key] = value }
            return value
        }
        
        return value
    }
}

// MARK: - Storage Setting Convenience

public extension Dependencies {
    subscript(singleton singleton: SingletonInfo.Config<Storage>, key key: Setting.BoolKey) -> Bool {
        return self[singleton: singleton]
            .read { db in db[key] }
            .defaulting(to: false)  // Default to false if it doesn't exist
    }
    
    subscript(singleton singleton: SingletonInfo.Config<Storage>, key key: Setting.DoubleKey) -> Double? {
        return self[singleton: singleton].read { db in db[key] }
    }
    
    subscript(singleton singleton: SingletonInfo.Config<Storage>, key key: Setting.IntKey) -> Int? {
        return self[singleton: singleton].read { db in db[key] }
    }
    
    subscript(singleton singleton: SingletonInfo.Config<Storage>, key key: Setting.StringKey) -> String? {
        return self[singleton: singleton].read { db in db[key] }
    }
    
    subscript(singleton singleton: SingletonInfo.Config<Storage>, key key: Setting.DateKey) -> Date? {
        return self[singleton: singleton].read { db in db[key] }
    }
    
    subscript<T: EnumIntSetting>(singleton singleton: SingletonInfo.Config<Storage>, key key: Setting.EnumKey) -> T? {
        return self[singleton: singleton].read { db in db[key] }
    }
    
    subscript<T: EnumStringSetting>(singleton singleton: SingletonInfo.Config<Storage>, key key: Setting.EnumKey) -> T? {
        return self[singleton: singleton].read { db in db[key] }
    }
}

// MARK: - UserDefaults Convenience

public extension Dependencies {
    subscript(defaults defaults: UserDefaultsInfo.Config, key key: UserDefaultsInfo.BoolKey) -> Bool {
        get { return self[defaults: defaults].bool(forKey: key.rawValue) }
        set { self[defaults: defaults].set(newValue, forKey: key.rawValue) }
    }

    subscript(defaults defaults: UserDefaultsInfo.Config, key key: UserDefaultsInfo.DateKey) -> Date? {
        get { return self[defaults: defaults].object(forKey: key.rawValue) as? Date }
        set { self[defaults: defaults].set(newValue, forKey: key.rawValue) }
    }
    
    subscript(defaults defaults: UserDefaultsInfo.Config, key key: UserDefaultsInfo.DoubleKey) -> Double {
        get { return self[defaults: defaults].double(forKey: key.rawValue) }
        set { self[defaults: defaults].set(newValue, forKey: key.rawValue) }
    }

    subscript(defaults defaults: UserDefaultsInfo.Config, key key: UserDefaultsInfo.IntKey) -> Int {
        get { return self[defaults: defaults].integer(forKey: key.rawValue) }
        set { self[defaults: defaults].set(newValue, forKey: key.rawValue) }
    }
    
    subscript(defaults defaults: UserDefaultsInfo.Config, key key: UserDefaultsInfo.StringKey) -> String? {
        get { return self[defaults: defaults].string(forKey: key.rawValue) }
        set { self[defaults: defaults].set(newValue, forKey: key.rawValue) }
    }
}
