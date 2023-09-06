// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

public extension SnodeAPI.AuthenticationInfo {
    init(
        _ db: Database,
        threadId: String,
        using dependencies: Dependencies
    ) throws {
        switch SessionId.Prefix(from: threadId) {
            case .standard:
                guard let keyPair: KeyPair = Identity.fetchUserEd25519KeyPair(db, using: dependencies) else {
                    throw SnodeAPIError.noKeyPair
                }
                
                self = .standard(pubkey: threadId, ed25519KeyPair: keyPair)
                
            case .group:
                struct GroupAuthData: Codable, FetchableRecord {
                    let groupIdentityPrivateKey: Data?
                    let authData: Data?
                }
                
                let authData: GroupAuthData? = try? ClosedGroup
                    .filter(id: threadId)
                    .select(.authData, .groupIdentityPrivateKey)
                    .asRequest(of: GroupAuthData.self)
                    .fetchOne(db)
                
                switch (authData?.groupIdentityPrivateKey, authData?.authData) {
                    case (.some(let privateKey), _):
                        self = .groupAdmin(pubkey: threadId, ed25519SecretKey: Array(privateKey))
                        
                    case (_, .some(let authData)): self = .groupMember(pubkey: threadId, authData: authData)
                    default: throw SnodeAPIError.invalidAuthentication
                }
                
            default: throw SnodeAPIError.invalidAuthentication
        }
    }
}
