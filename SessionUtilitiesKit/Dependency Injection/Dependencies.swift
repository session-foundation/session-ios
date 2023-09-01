// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

public class Dependencies {
    private static var singletonInstances: Atomic<[Int: Any]> = Atomic([:])
    private static var cacheInstances: Atomic<[Int: MutableCacheType]> = Atomic([:])
    
    // MARK: - Subscript Access
    
    public subscript<S>(singleton singleton: SingletonInfo.Config<S>) -> S {
        getValueSettingIfNull(singleton: singleton, &Dependencies.singletonInstances)
    }
    
    public subscript<M, I>(cache cache: CacheInfo.Config<M, I>) -> I {
        getValueSettingIfNull(cache: cache, &Dependencies.cacheInstances)
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
}
