// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

// MARK: - CacheType

public protocol MutableCacheType {}
public protocol ImmutableCacheType {}

// MARK: - Cache

public class Cache {}

// MARK: - CacheInfo

public enum CacheInfo {
    public class Config<M, I>: Cache {
        public let key: Int
        public let createInstance: () -> M
        public let mutableInstance: (M) -> MutableCacheType
        public let immutableInstance: (M) -> I
        
        fileprivate init(
            createInstance: @escaping () -> M,
            mutableInstance: @escaping (M) -> MutableCacheType,
            immutableInstance: @escaping (M) -> I
        ) {
            self.key = ObjectIdentifier(M.self).hashValue
            self.createInstance = createInstance
            self.mutableInstance = mutableInstance
            self.immutableInstance = immutableInstance
        }
    }
}

public extension CacheInfo {
    static func create<M, I>(
        createInstance: @escaping () -> M,
        mutableInstance: @escaping (M) -> MutableCacheType,
        immutableInstance: @escaping (M) -> I
    ) -> CacheInfo.Config<M, I> {
        return CacheInfo.Config(
            createInstance: createInstance,
            mutableInstance: mutableInstance,
            immutableInstance: immutableInstance
        )
    }
}


public protocol CacheType: MutableCacheType {
    associatedtype ImmutableCache = ImmutableCacheType
    associatedtype MutableCache: MutableCacheType
    
    init()
    func mutableInstance() -> MutableCache
    func immutableInstance() -> ImmutableCache
}

public extension CacheType where MutableCache == Self {
    func mutableInstance() -> Self { return self }
}

public protocol CachesType {
    subscript<M, I>(cache: CacheInfo.Config<M, I>) -> I { get }
    
    @discardableResult func mutate<M, I, R>(
        cache: CacheInfo.Config<M, I>,
        _ mutation: (inout M) -> R
    ) -> R
    @discardableResult func mutate<M, I, R>(
        cache: CacheInfo.Config<M, I>,
        _ mutation: (inout M) throws -> R
    ) throws -> R
}

// MARK: - Caches Logic

public extension Dependencies {
    class Caches: CachesType {
        /// The caches need to be accessed as singleton instances so we store them in a static variable in the `Caches` type
        private static var cacheInstances: Atomic<[Int: MutableCacheType]> = Atomic([:])
        
        // MARK: - Initialization
        
        public init() {}
        
        // MARK: - Immutable Access
        
        public subscript<M, I>(cache: CacheInfo.Config<M, I>) -> I {
            get { Caches.getValueSettingIfNull(cache: cache, &Caches.cacheInstances) }
        }
        
        // MARK: - Mutable Access
        
        @discardableResult public func mutate<M, I, R>(cache: CacheInfo.Config<M, I>, _ mutation: (inout M) -> R) -> R {
            return Caches.cacheInstances.mutate { caches in
                var value: M = ((caches[cache.key] as? M) ?? cache.createInstance())
                return mutation(&value)
            }
        }
        
        @discardableResult public func mutate<M, I, R>(cache: CacheInfo.Config<M, I>, _ mutation: (inout M) throws -> R) throws -> R {
            return try Caches.cacheInstances.mutate { caches in
                var value: M = ((caches[cache.key] as? M) ?? cache.createInstance())
                return try mutation(&value)
            }
        }
        
        // MARK: - Convenience
        
        @discardableResult private static func getValueSettingIfNull<M, I>(
            cache: CacheInfo.Config<M, I>,
            _ store: inout Atomic<[Int: MutableCacheType]>
        ) -> I {
            guard let value: M = (store.wrappedValue[cache.key] as? M) else {
                let value: M = cache.createInstance()
                let mutableInstance: MutableCacheType = cache.mutableInstance(value)
                store.mutate { $0[cache.key] = mutableInstance }
                return cache.immutableInstance(value)
            }
            
            return cache.immutableInstance(value)
        }
    }
}
