// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

public extension SnodeAPI.AuthenticationInfo {
    init(
        _ db: Database,
        sessionIdHexString: String,
        using dependencies: Dependencies
    ) throws {
        switch try? SessionId(from: sessionIdHexString) {
            case .some(let sessionId) where sessionId.prefix == .standard:
                guard let keyPair: KeyPair = Identity.fetchUserEd25519KeyPair(db, using: dependencies) else {
                    throw SnodeAPIError.noKeyPair
                }
                
                self = .standard(sessionId: sessionId, ed25519KeyPair: keyPair)
                
            case .some(let sessionId) where sessionId.prefix == .group:
                struct GroupAuthData: Codable, FetchableRecord {
                    let groupIdentityPrivateKey: Data?
                    let authData: Data?
                }
                
                let authData: GroupAuthData? = try? ClosedGroup
                    .filter(id: sessionIdHexString)
                    .select(.authData, .groupIdentityPrivateKey)
                    .asRequest(of: GroupAuthData.self)
                    .fetchOne(db)
                
                switch (authData?.groupIdentityPrivateKey, authData?.authData) {
                    case (.some(let privateKey), _):
                        self = .groupAdmin(groupSessionId: sessionId, ed25519SecretKey: Array(privateKey))
                        
                    case (_, .some(let authData)):
                        self = .groupMember(groupSessionId: sessionId, authData: authData)
                        
                    default: throw SnodeAPIError.invalidAuthentication
                }
                
            default: throw SnodeAPIError.invalidAuthentication
        }
    }
}
