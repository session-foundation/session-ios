// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

// MARK: - Cache

public class Cache {}

// MARK: - Cache Types

public protocol MutableCacheType {}
public protocol ImmutableCacheType {}

// MARK: - CacheInfo

public enum CacheInfo {
    public class Config<M, I>: Cache {
        public let key: Int
        public let createInstance: (Dependencies) -> M
        public let mutableInstance: (M) -> MutableCacheType
        public let immutableInstance: (M) -> I
        
        fileprivate init(
            createInstance: @escaping (Dependencies) -> M,
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
        createInstance: @escaping (Dependencies) -> M,
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
