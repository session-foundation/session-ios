// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit

public extension Network {
    enum StorageServer {
        public static let maxRetryCount: Int = 8
    }
}

// MARK: - StorageServer Cache

public extension Network.StorageServer {
    class Cache: StorageServerCacheType {
        private let dependencies: Dependencies
        public var hardfork: Int
        public var softfork: Int
        public var clockOffsetMs: Int64 = 0
        
        init(using dependencies: Dependencies) {
            self.dependencies = dependencies
            self.hardfork = dependencies[defaults: .standard, key: .hardfork]
            self.softfork = dependencies[defaults: .standard, key: .softfork]
        }
        
        public func currentOffsetTimestampMs<T: Numeric>() -> T {
            let timestampNowMs: Int64 = (Int64(floor(dependencies.dateNow.timeIntervalSince1970 * 1000)) + clockOffsetMs)
            
            guard let convertedTimestampNowMs: T = T(exactly: timestampNowMs) else {
                Log.critical("[SnodeAPI.Cache] Failed to convert the timestamp to the desired type: \(type(of: T.self)).")
                return 0
            }
            
            return convertedTimestampNowMs
        }
        
        public func setClockOffsetMs(_ clockOffsetMs: Int64) {
            self.clockOffsetMs = clockOffsetMs
        }
    }
}

public extension Cache {
    static let storageServer: CacheConfig<StorageServerCacheType, StorageServerImmutableCacheType> = Dependencies.create(
        identifier: "storageServer",
        createInstance: { dependencies, _ in Network.StorageServer.Cache(using: dependencies) },
        mutableInstance: { $0 },
        immutableInstance: { $0 }
    )
}

// MARK: - SnodeAPICacheType

/// This is a read-only version of the Cache designed to avoid unintentionally mutating the instance in a non-thread-safe way
public protocol StorageServerImmutableCacheType: ImmutableCacheType {
    /// The last seen storage server hard fork version.
    var hardfork: Int { get }
    
    /// The last seen storage server soft fork version.
    var softfork: Int { get }

    /// The offset between the user's clock and the Service Node's clock. Used in cases where the
    /// user's clock is incorrect.
    var clockOffsetMs: Int64 { get }
    
    /// Tthe current user clock timestamp in milliseconds offset by the difference between the user's clock and the clock of the most
    /// recent Service Node's that was communicated with.
    func currentOffsetTimestampMs<T: Numeric>() -> T
}

public protocol StorageServerCacheType: StorageServerImmutableCacheType, MutableCacheType {
    /// The last seen storage server hard fork version.
    var hardfork: Int { get set }
    
    /// The last seen storage server soft fork version.
    var softfork: Int { get set }

    /// A function to update the offset between the user's clock and the Service Node's clock.
    func setClockOffsetMs(_ clockOffsetMs: Int64)
}
