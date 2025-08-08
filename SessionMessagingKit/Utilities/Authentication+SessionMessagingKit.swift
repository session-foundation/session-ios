// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionNetworkingKit
import SessionUtilitiesKit

// MARK: - Authentication Types

public extension Authentication {
    /// Used when interacting as the current user
    struct standard: AuthenticationMethod {
        public let sessionId: SessionId
        public let ed25519PublicKey: [UInt8]
        public let ed25519SecretKey: [UInt8]
        
        public var info: Info { .standard(sessionId: sessionId, ed25519PublicKey: ed25519PublicKey) }
        
        public init(sessionId: SessionId, ed25519PublicKey: [UInt8], ed25519SecretKey: [UInt8]) {
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
    struct groupAdmin: AuthenticationMethod {
        public let groupSessionId: SessionId
        public let ed25519SecretKey: [UInt8]
        
        public var info: Info { .groupAdmin(groupSessionId: groupSessionId, ed25519SecretKey: ed25519SecretKey) }
        
        public init(groupSessionId: SessionId, ed25519SecretKey: [UInt8]) {
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
    struct groupMember: AuthenticationMethod {
        public let groupSessionId: SessionId
        public let authData: Data
        
        public var info: Info { .groupMember(groupSessionId: groupSessionId, authData: authData) }
        
        public init(groupSessionId: SessionId, authData: Data) {
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
    
    /// Used when interacting with a community
    struct community: AuthenticationMethod {
        public let openGroupCapabilityInfo: LibSession.OpenGroupCapabilityInfo
        public let forceBlinded: Bool
        
        public var server: String { openGroupCapabilityInfo.server }
        public var publicKey: String { openGroupCapabilityInfo.publicKey }
        public var hasCapabilities: Bool { !openGroupCapabilityInfo.capabilities.isEmpty }
        public var supportsBlinding: Bool { openGroupCapabilityInfo.capabilities.contains(.blind) }
        
        public var info: Info {
            .community(
                server: server,
                publicKey: publicKey,
                hasCapabilities: hasCapabilities,
                supportsBlinding: supportsBlinding,
                forceBlinded: forceBlinded
            )
        }
        
        public init(info: LibSession.OpenGroupCapabilityInfo, forceBlinded: Bool = false) {
            self.openGroupCapabilityInfo = info
            self.forceBlinded = forceBlinded
        }
        
        // MARK: - SignatureGenerator
        
        public func generateSignature(with verificationBytes: [UInt8], using dependencies: Dependencies) throws -> Authentication.Signature {
            throw CryptoError.signatureGenerationFailed
        }
    }
}

// MARK: - Convenience

fileprivate struct GroupAuthData: Codable, FetchableRecord {
    let groupIdentityPrivateKey: Data?
    let authData: Data?
}

public extension Authentication {
    static func with(
        _ db: ObservingDatabase,
        server: String,
        activeOnly: Bool = true,
        forceBlinded: Bool = false,
        using dependencies: Dependencies
    ) throws -> AuthenticationMethod {
        guard
            // TODO: [Database Relocation] Store capability info locally in libSession so we don't need the db here
            let info: LibSession.OpenGroupCapabilityInfo = try? LibSession.OpenGroupCapabilityInfo
                .fetchOne(db, server: server, activeOnly: activeOnly)
        else { throw CryptoError.invalidAuthentication }
        
        return Authentication.community(info: info, forceBlinded: forceBlinded)
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
                
                return Authentication.community(info: info, forceBlinded: forceBlinded)
                
            case (.contact, .blinded15), (.contact, .blinded25):
                guard
                    let lookup: BlindedIdLookup = try? BlindedIdLookup.fetchOne(db, id: threadId),
                    let info: LibSession.OpenGroupCapabilityInfo = try? LibSession.OpenGroupCapabilityInfo
                        .fetchOne(db, server: lookup.openGroupServer)
                else { throw CryptoError.invalidAuthentication }
                
                return Authentication.community(info: info, forceBlinded: forceBlinded)
                
            default: return try Authentication.with(db, swarmPublicKey: threadId, using: dependencies)
        }
    }
    
    static func with(
        _ db: ObservingDatabase,
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
                let authData: GroupAuthData? = try? ClosedGroup
                    .filter(id: swarmPublicKey)
                    .select(.authData, .groupIdentityPrivateKey)
                    .asRequest(of: GroupAuthData.self)
                    .fetchOne(db)
                
                switch (authData?.groupIdentityPrivateKey, authData?.authData) {
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
