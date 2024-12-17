// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

// MARK: - CacheType

public protocol MutableCacheType: AnyObject {}
public protocol ImmutableCacheType: AnyObject {}

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
        _ mutation: (M) -> R
    ) -> R
    @discardableResult func mutate<M, I, R>(
        cache: CacheInfo.Config<M, I>,
        _ mutation: (M) throws -> R
    ) throws -> R
}

// MARK: - Caches Logic

public extension Dependencies {
    class Caches: CachesType {
        /// The caches need to be accessed as singleton instances so we store them in a static variable in the `Caches` type
        @ThreadSafeObject private static var cacheInstances: [Int: MutableCacheType] = [:]
        
        // MARK: - Initialization
        
        public init() {}
        
        // MARK: - Immutable Access
        
        public subscript<M, I>(cache: CacheInfo.Config<M, I>) -> I {
            get {
                guard let value: M = (Caches.cacheInstances[cache.key] as? M) else {
                    let value: M = cache.createInstance()
                    let mutableInstance: MutableCacheType = cache.mutableInstance(value)
                    Caches._cacheInstances.performUpdate { $0.setting(cache.key, mutableInstance) }
                    return cache.immutableInstance(value)
                }
                
                return cache.immutableInstance(value)
            }
        }
        
        // MARK: - Mutable Access
        
        @discardableResult public func mutate<M, I, R>(cache: CacheInfo.Config<M, I>, _ mutation: (M) -> R) -> R {
            return Caches._cacheInstances.performUpdateAndMap { caches in
                switch caches[cache.key] as? M {
                    case .some(let value):
                        let result: R = mutation(value)
                        return (caches, result)
                    
                    case .none:
                        let value: M = cache.createInstance()
                        let result: R = mutation(value)
                        return (caches.setting(cache.key, cache.mutableInstance(value)), result)
                }
            }
        }
        
        @discardableResult public func mutate<M, I, R>(cache: CacheInfo.Config<M, I>, _ mutation: (M) throws -> R) throws -> R {
            return try Caches._cacheInstances.performUpdateAndMap { caches in
                switch caches[cache.key] as? M {
                    case .some(let value):
                        let result: R = try mutation(value)
                        return (caches, result)
                    
                    case .none:
                        let value: M = cache.createInstance()
                        let result: R = try mutation(value)
                        return (caches.setting(cache.key, cache.mutableInstance(value)), result)
                }
            }
        }
    }
}
