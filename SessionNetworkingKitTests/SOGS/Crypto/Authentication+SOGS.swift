// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

// MARK: - Authentication Types

public extension Authentication {
    static func community(
        roomToken: String,
        server: String,
        publicKey: String,
        hasCapabilities: Bool,
        supportsBlinding: Bool,
        forceBlinded: Bool = false
    ) -> AuthenticationMethod {
        return Community(
            roomToken: roomToken,
            server: server,
            publicKey: publicKey,
            hasCapabilities: hasCapabilities,
            supportsBlinding: supportsBlinding,
            forceBlinded: forceBlinded
        )
    }
    
    /// Used when interacting with a community
    struct Community: AuthenticationMethod {
        public let roomToken: String
        public let server: String
        public let publicKey: String
        public let hasCapabilities: Bool
        public let supportsBlinding: Bool
        public let forceBlinded: Bool
        
        public var info: Info {
            .community(
                server: server,
                publicKey: publicKey,
                hasCapabilities: hasCapabilities,
                supportsBlinding: supportsBlinding,
                forceBlinded: forceBlinded
            )
        }
        
        public init(
            roomToken: String,
            server: String,
            publicKey: String,
            hasCapabilities: Bool,
            supportsBlinding: Bool,
            forceBlinded: Bool
        ) {
            self.roomToken = roomToken
            self.server = server
            self.publicKey = publicKey
            self.hasCapabilities = hasCapabilities
            self.supportsBlinding = supportsBlinding
            self.forceBlinded = forceBlinded
        }
        
        // MARK: - SignatureGenerator
        
        public func generateSignature(with verificationBytes: [UInt8], using dependencies: Dependencies) throws -> Authentication.Signature {
            throw CryptoError.signatureGenerationFailed
        }
    }
}
