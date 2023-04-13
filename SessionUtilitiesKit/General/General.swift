// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import Curve25519Kit

public protocol GeneralCacheType {
    var encodedPublicKey: String? { get set }
    var recentReactionTimestamps: [Int64] { get set }
}

public enum General {
    public class Cache: GeneralCacheType {
        public var encodedPublicKey: String? = nil
        public var recentReactionTimestamps: [Int64] = []
    }
    
    public static var cache: Atomic<GeneralCacheType> = Atomic(Cache())
}

public enum GeneralError: Error {
    case invalidSeed
    case keyGenerationFailed
}

public func getUserHexEncodedPublicKey(_ db: Database? = nil, dependencies: Dependencies = Dependencies()) -> String {
    if let cachedKey: String = dependencies.generalCache.wrappedValue.encodedPublicKey { return cachedKey }
    
    if let publicKey: Data = Identity.fetchUserPublicKey(db) { // Can be nil under some circumstances
        let sessionId: SessionId = SessionId(.standard, publicKey: publicKey.bytes)
        
        dependencies.generalCache.mutate { $0.encodedPublicKey = sessionId.hexString }
        return sessionId.hexString
    }
    
    return ""
}
