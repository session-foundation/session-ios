// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

class MockCaches: CachesType {
    private var cacheInstances: [Int: MutableCacheType] = [:]
    
    // MARK: - Immutable Access
    
    public subscript<M, I>(cache: CacheInfo.Config<M, I>) -> I {
        get { MockCaches.getValueSettingIfNull(cache: cache, &cacheInstances) }
    }
    
    public subscript<M, I>(cache: CacheInfo.Config<M, I>) -> M? {
        get { return (cacheInstances[cache.key] as? M) }
        set { cacheInstances[cache.key] = newValue.map { cache.mutableInstance($0) } }
    }
    
    // MARK: - Mutable Access
    
    @discardableResult public func mutate<M, I, R>(
        cache: CacheInfo.Config<M, I>,
        _ mutation: (inout M) -> R
    ) -> R {
        var value: M = ((cacheInstances[cache.key] as? M) ?? cache.createInstance())
        return mutation(&value)
    }
    
    @discardableResult public func mutate<M, I, R>(
        cache: CacheInfo.Config<M, I>,
        _ mutation: (inout M) throws -> R
    ) throws -> R {
        var value: M = ((cacheInstances[cache.key] as? M) ?? cache.createInstance())
        return try mutation(&value)
    }
    
    @discardableResult private static func getValueSettingIfNull<M, I>(
        cache: CacheInfo.Config<M, I>,
        _ store: inout [Int: MutableCacheType]
    ) -> I {
        guard let value: M = (store[cache.key] as? M) else {
            let value: M = cache.createInstance()
            let mutableInstance: MutableCacheType = cache.mutableInstance(value)
            store[cache.key] = mutableInstance
            return cache.immutableInstance(value)
        }
        
        return cache.immutableInstance(value)
    }
}
