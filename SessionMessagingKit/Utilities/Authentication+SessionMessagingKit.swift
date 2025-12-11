// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionNetworkingKit
import SessionUtilitiesKit

// MARK: - Authentication Types

public extension Authentication {
    static func standard(sessionId: SessionId, ed25519PublicKey: [UInt8], ed25519SecretKey: [UInt8]) -> AuthenticationMethod {
        return Standard(
            sessionId: sessionId,
            ed25519PublicKey: ed25519PublicKey,
            ed25519SecretKey: ed25519SecretKey
        )
    }
    
    static func groupAdmin(groupSessionId: SessionId, ed25519SecretKey: [UInt8]) -> AuthenticationMethod {
        return GroupAdmin(
            groupSessionId: groupSessionId,
            ed25519SecretKey: ed25519SecretKey
        )
    }
    
    static func groupMember(groupSessionId: SessionId, authData: Data) -> AuthenticationMethod {
        return GroupMember(
            groupSessionId: groupSessionId,
            authData: authData
        )
    }
    
    /// Used when interacting as the current user
    struct Standard: AuthenticationMethod {
        public let sessionId: SessionId
        public let ed25519PublicKey: [UInt8]
        public let ed25519SecretKey: [UInt8]
        
        public var info: Info { .standard(sessionId: sessionId, ed25519PublicKey: ed25519PublicKey) }
        
        fileprivate init(sessionId: SessionId, ed25519PublicKey: [UInt8], ed25519SecretKey: [UInt8]) {
            self.sessionId = sessionId
            self.ed25519PublicKey = ed25519PublicKey
            self.ed25519SecretKey = ed25519SecretKey
        }
        
        // MARK: - SignatureGenerator
        
        public func generateSignature(with verificationBytes: [UInt8], using dependencies: Dependencies) throws -> Authentication.Signature {
            return try dependencies[singleton: .crypto].tryGenerate(
                .signature(message: verificationBytes, ed25519SecretKey: ed25519SecretKey)
            )
        }
    }
    
    /// Used when interacting as a group admin
    struct GroupAdmin: AuthenticationMethod {
        public let groupSessionId: SessionId
        public let ed25519SecretKey: [UInt8]
        
        public var info: Info { .groupAdmin(groupSessionId: groupSessionId, ed25519SecretKey: ed25519SecretKey) }
        
        fileprivate init(groupSessionId: SessionId, ed25519SecretKey: [UInt8]) {
            self.groupSessionId = groupSessionId
            self.ed25519SecretKey = ed25519SecretKey
        }
        
        // MARK: - SignatureGenerator
        
        public func generateSignature(with verificationBytes: [UInt8], using dependencies: Dependencies) throws -> Authentication.Signature {
            return try dependencies[singleton: .crypto].tryGenerate(
                .signature(message: verificationBytes, ed25519SecretKey: ed25519SecretKey)
            )
        }
    }

    /// Used when interacting as a group member
    struct GroupMember: AuthenticationMethod {
        public let groupSessionId: SessionId
        public let authData: Data
        
        public var info: Info { .groupMember(groupSessionId: groupSessionId, authData: authData) }
        
        fileprivate init(groupSessionId: SessionId, authData: Data) {
            self.groupSessionId = groupSessionId
            self.authData = authData
        }
        
        // MARK: - SignatureGenerator
        
        public func generateSignature(with verificationBytes: [UInt8], using dependencies: Dependencies) throws -> Authentication.Signature {
            return try dependencies.mutate(cache: .libSession) { cache in
                try dependencies[singleton: .crypto].tryGenerate(
                    .signatureSubaccount(
                        config: cache.config(for: .groupKeys, sessionId: groupSessionId),
                        verificationBytes: verificationBytes,
                        memberAuthData: authData
                    )
                )
            }
        }
    }
}

// MARK: - Convenience

public extension Authentication.Community {
    init(info: LibSession.OpenGroupCapabilityInfo, forceBlinded: Bool = false) {
        self.init(
            roomToken: info.roomToken,
            server: info.server,
            publicKey: info.publicKey,
            hasCapabilities: !info.capabilities.isEmpty,
            supportsBlinding: info.capabilities.contains(.blind),
            forceBlinded: forceBlinded
        )
    }
}

public extension Authentication {
    static func with(
        _ db: ObservingDatabase,
        server: String,
        activelyPollingOnly: Bool = true,
        forceBlinded: Bool = false,
        using dependencies: Dependencies
    ) throws -> AuthenticationMethod {
        guard
            // TODO: [Database Relocation] Store capability info locally in libSession so we don't need the db here
            let info: LibSession.OpenGroupCapabilityInfo = try? LibSession.OpenGroupCapabilityInfo
                .fetchOne(db, server: server, activelyPollingOnly: activelyPollingOnly)
        else { throw CryptoError.invalidAuthentication }
        
        return Authentication.Community(info: info, forceBlinded: forceBlinded)
    }
    
    static func with(
        _ db: ObservingDatabase,
        threadId: String,
        threadVariant: SessionThread.Variant,
        forceBlinded: Bool = false,
        using dependencies: Dependencies
    ) throws -> AuthenticationMethod {
        switch (threadVariant, try? SessionId.Prefix(from: threadId)) {
            case (.community, _):
                guard
                    // TODO: [Database Relocation] Store capability info locally in libSession so we don't need the db here
                    let info: LibSession.OpenGroupCapabilityInfo = try? LibSession.OpenGroupCapabilityInfo
                        .fetchOne(db, id: threadId)
                else { throw CryptoError.invalidAuthentication }
                
                return Authentication.Community(info: info, forceBlinded: forceBlinded)
                
            case (.contact, .blinded15), (.contact, .blinded25):
                guard
                    let lookup: BlindedIdLookup = try? BlindedIdLookup.fetchOne(db, id: threadId),
                    let info: LibSession.OpenGroupCapabilityInfo = try? LibSession.OpenGroupCapabilityInfo
                        .fetchOne(db, server: lookup.openGroupServer)
                else { throw CryptoError.invalidAuthentication }
                
                return Authentication.Community(info: info, forceBlinded: forceBlinded)
                
            default: return try Authentication.with(swarmPublicKey: threadId, using: dependencies)
        }
    }
    
    static func with(
        swarmPublicKey: String,
        using dependencies: Dependencies
    ) throws -> AuthenticationMethod {
        switch try? SessionId(from: swarmPublicKey) {
            case .some(let sessionId) where sessionId.prefix == .standard:
                guard
                    let userEdKeyPair: KeyPair = dependencies[singleton: .crypto].generate(
                        .ed25519KeyPair(seed: dependencies[cache: .general].ed25519Seed)
                    )
                else { throw SnodeAPIError.noKeyPair }
                
                return Authentication.standard(
                    sessionId: sessionId,
                    ed25519PublicKey: userEdKeyPair.publicKey,
                    ed25519SecretKey: userEdKeyPair.secretKey
                )
                
            case .some(let sessionId) where sessionId.prefix == .group:
                let authData: GroupAuthData = dependencies.mutate(cache: .libSession) { libSession in
                    libSession.authData(groupSessionId: SessionId(.group, hex: swarmPublicKey))
                }
                
                switch (authData.groupIdentityPrivateKey, authData.authData) {
                    case (.some(let privateKey), _):
                        return Authentication.groupAdmin(
                            groupSessionId: sessionId,
                            ed25519SecretKey: Array(privateKey)
                        )
                        
                    case (_, .some(let authData)):
                        return Authentication.groupMember(
                            groupSessionId: sessionId,
                            authData: authData
                        )
                        
                    default: throw CryptoError.invalidAuthentication
                }
                
            default: throw CryptoError.invalidAuthentication
        }
    }
}
