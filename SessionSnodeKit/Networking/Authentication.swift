// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

public extension SnodeAPI {
    enum AuthenticationInfo: Equatable {
        /// Used for when interacting as the current user
        case standard(sessionId: SessionId, ed25519KeyPair: KeyPair)
        
        /// Used for when interacting as a group admin
        case groupAdmin(groupSessionId: SessionId, ed25519SecretKey: [UInt8])
        
        /// Used for when interacting as a group member
        case groupMember(groupSessionId: SessionId, authData: Data)
        
        // MARK: - Variables
        
        public var sessionId: SessionId {
            switch self {
                case .standard(let sessionId, _), .groupAdmin(let sessionId, _), .groupMember(let sessionId, _):
                    return sessionId
            }
        }
        
        // MARK: - Functions
        
        public func generateSignature(
            with verificationBytes: [UInt8],
            using dependencies: Dependencies
        ) throws -> [UInt8] {
            switch self {
                case .standard(_, let ed25519KeyPair):
                    return try dependencies[singleton: .crypto].perform(
                        .signature(message: verificationBytes, secretKey: ed25519KeyPair.secretKey)
                    )
                
                case .groupAdmin(_, let ed25519SecretKey):
                    return try dependencies[singleton: .crypto].perform(
                        .signature(message: verificationBytes, secretKey: ed25519SecretKey)
                    )
                    
                case .groupMember(_, let authData):
                    preconditionFailure()
            }
        }
    }
}
