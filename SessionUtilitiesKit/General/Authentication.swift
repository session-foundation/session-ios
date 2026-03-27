// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

public enum Authentication {}
public protocol AuthenticationMethod: Sendable, SignatureGenerator {
    var info: Authentication.Info { get }
}

public extension AuthenticationMethod {
    var isInvalid: Bool {
        switch info {
            case .standard(let sessionId, let ed25519PublicKey):
                return (sessionId == .invalid || ed25519PublicKey.isEmpty)
                
            default: return false
        }
    }
    
    var swarmPublicKey: String {
        get throws {
            switch info {
                case .standard(let sessionId, _), .groupAdmin(let sessionId, _), .groupMember(let sessionId, _):
                    return sessionId.hexString
                    
                case .community: throw CryptoError.invalidAuthentication
            }
        }
    }
}

public extension Authentication {
    static let invalid: AuthenticationMethod = Invalid()
    
    struct Invalid: AuthenticationMethod {
        public var info: Authentication.Info = .standard(sessionId: .invalid, ed25519PublicKey: [])
        
        public func generateSignature(with verificationBytes: [UInt8], using dependencies: Dependencies) throws -> Authentication.Signature {
            throw CryptoError.invalidAuthentication
        }
    }
}

public struct EquatableAuthenticationMethod: Sendable, Equatable {
    public let value: AuthenticationMethod
    
    public init(value: AuthenticationMethod) {
        self.value = value
    }
    
    public static func ==(lhs: EquatableAuthenticationMethod, rhs: EquatableAuthenticationMethod) -> Bool {
        return (lhs.value.info == rhs.value.info)
    }
}

// MARK: - SignatureGenerator

public protocol SignatureGenerator {
    func generateSignature(
        with verificationBytes: [UInt8],
        using dependencies: Dependencies
    ) throws -> Authentication.Signature
}

// MARK: - Signature Verification

public extension Authentication {
    static func verify(
        signature: Authentication.Signature,
        publicKey: [UInt8],
        verificationBytes: [UInt8],
        using dependencies: Dependencies
    ) -> Bool {
        switch signature {
            case .standard(let signature):
                return dependencies[singleton: .crypto].verify(
                    .signature(message: verificationBytes, publicKey: publicKey, signature: signature)
                )
                
            // Currently we never sign anything with a subaccount which requires verification
            case .subaccount: return false
        }
    }
}

// MARK: - Authentication.Info

public extension Authentication {
    enum Info: Sendable, Equatable {
        /// Used when interacting as the current user
        case standard(sessionId: SessionId, ed25519PublicKey: [UInt8])
        
        /// Used when interacting as a group admin
        case groupAdmin(groupSessionId: SessionId, ed25519SecretKey: [UInt8])
        
        /// Used when interacting as a group member
        case groupMember(groupSessionId: SessionId, authData: Data)
        
        /// Used when interacting with a community
        case community(
            server: String,
            publicKey: String,
            hasCapabilities: Bool,
            supportsBlinding: Bool,
            forceBlinded: Bool
        )
    }
}

// MARK: - Authentication.Signature

public extension Authentication {
    enum Signature: Equatable, CustomStringConvertible {
        /// Used for signing standard requests
        case standard(signature: [UInt8])
        
        /// Used for signing standard requests
        case subaccount(subaccount: [UInt8], subaccountSig: [UInt8], signature: [UInt8])
        
        // MARK: - CustomStringConvertible
        
        public var description: String {
            switch self {
                case .standard(let signature):
                    return """
                    standard(
                        signature: \(signature.toHexString())
                    )
                    """
                    
                case .subaccount(let subaccount, let subaccountSig, let signature):
                    return """
                    subaccount(
                        subaccount: \(subaccount.toHexString()),
                        subaccountSig: \(subaccountSig.toHexString()),
                        signature: \(signature.toHexString())
                    )
                    """
            }
        }
    }
}

public extension Optional where Wrapped == Authentication.Signature {
    var nullIfEmpty: Authentication.Signature? {
        switch self {
            case .none: return nil
            case .standard(let signature):
                guard !signature.isEmpty else { return nil }
                
                return self
                
            case .subaccount(let subaccount, let subaccountSig, let signature):
                guard !subaccount.isEmpty, !subaccountSig.isEmpty, !signature.isEmpty else { return nil }
                
                return self
        }
    }
}
