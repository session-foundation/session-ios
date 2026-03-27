// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import GRDB

// MARK: - Cache

public extension Cache {
    static let general: CacheConfig<GeneralCacheType, ImmutableGeneralCacheType> = Dependencies.create(
        identifier: "general",
        createInstance: { dependencies, _ in General.Cache(using: dependencies) },
        mutableInstance: { $0 },
        immutableInstance: { $0 }
    )
}

// MARK: - General.Cache

public enum General {
    public class Cache: GeneralCacheType {
        private let dependencies: Dependencies
        public var sessionId: SessionId = SessionId.invalid
        public var ed25519SecretKey: [UInt8] = []
        public var recentReactionTimestamps: [Int64] = []
        public var contextualActionLookupMap: [Int: [String: [Int: Any]]] = [:]
        
        public var userExists: Bool { !ed25519SecretKey.isEmpty }
        public var ed25519Seed: [UInt8] {
            guard ed25519SecretKey.count >= 32 else { return [] }
            
            return Array(ed25519SecretKey.prefix(upTo: 32))
        }
        
        // MARK: - Initialization
        
        init(using dependencies: Dependencies) {
            self.dependencies = dependencies
        }
        
        // MARK: - Functions
        
        public func setSecretKey(ed25519SecretKey: [UInt8]) {
            guard
                ed25519SecretKey.count >= 32,
                let ed25519KeyPair: KeyPair = dependencies[singleton: .crypto].generate(
                    .ed25519KeyPair(seed: Array(ed25519SecretKey.prefix(upTo: 32)))
                ),
                let x25519PublicKey: [UInt8] = dependencies[singleton: .crypto].generate(
                    .x25519(ed25519Pubkey: ed25519KeyPair.publicKey)
                )
            else {
                self.sessionId = .invalid
                self.ed25519SecretKey = []
                return
            }
            
            self.sessionId = SessionId(.standard, publicKey: x25519PublicKey)
            self.ed25519SecretKey = ed25519SecretKey
        }
    }
}

// MARK: - GeneralCacheType

/// This is a read-only version of the Cache designed to avoid unintentionally mutating the instance in a non-thread-safe way
public protocol ImmutableGeneralCacheType: ImmutableCacheType {
    var userExists: Bool { get }
    var sessionId: SessionId { get }
    var ed25519Seed: [UInt8] { get }
    var ed25519SecretKey: [UInt8] { get }
    var recentReactionTimestamps: [Int64] { get }
    var contextualActionLookupMap: [Int: [String: [Int: Any]]] { get }
}

public protocol GeneralCacheType: ImmutableGeneralCacheType, MutableCacheType {
    var userExists: Bool { get }
    var sessionId: SessionId { get }
    var ed25519Seed: [UInt8] { get }
    var ed25519SecretKey: [UInt8] { get }
    var recentReactionTimestamps: [Int64] { get set }
    var contextualActionLookupMap: [Int: [String: [Int: Any]]] { get set }
    
    func setSecretKey(ed25519SecretKey: [UInt8])
}
