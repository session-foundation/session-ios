// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

// MARK: - General.Cache

public enum General {
    public class Cache: MutableGeneralCacheType {
        public var encodedPublicKey: String? = nil
        public var recentReactionTimestamps: [Int64] = []
    }
}

// MARK: - GeneralError

public enum GeneralError: Error {
    case invalidSeed
    case keyGenerationFailed
    case randomGenerationFailed
}

// MARK: - Convenience

public func getUserHexEncodedPublicKey(_ db: Database? = nil, dependencies: Dependencies = Dependencies()) -> String {
    if let cachedKey: String = dependencies.generalCache.encodedPublicKey { return cachedKey }
    
    if let publicKey: Data = Identity.fetchUserPublicKey(db) { // Can be nil under some circumstances
        let sessionId: SessionId = SessionId(.standard, publicKey: publicKey.bytes)
        
        dependencies.mutableGeneralCache.mutate { $0.encodedPublicKey = sessionId.hexString }
        return sessionId.hexString
    }
    
    return ""
}

// MARK: - GeneralCacheType

public protocol MutableGeneralCacheType: GeneralCacheType {
    var encodedPublicKey: String? { get set }
    var recentReactionTimestamps: [Int64] { get set }
}

/// This is a read-only version of the `OGMMutableCacheType` designed to avoid unintentionally mutating the instance in a
/// non-thread-safe way
public protocol GeneralCacheType {
    var encodedPublicKey: String? { get }
    var recentReactionTimestamps: [Int64] { get }
}
