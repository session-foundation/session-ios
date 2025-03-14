// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

extension MessageReceiver {
    /// Some messages are encrypted with `libSession` and don't use Protobuf, this function decrypts those messages and
    /// routes them accordingly
    public static func handleLibSessionMessage(
        _ db: Database,
        threadId: String,
        threadVariant: SessionThread.Variant,
        message: LibSessionMessage,
        using dependencies: Dependencies
    ) throws {
        guard
            let sender: String = message.sender,
            let senderSessionId: SessionId = try? SessionId(from: sender),
            let userEd25519KeyPair: KeyPair = Identity.fetchUserEd25519KeyPair(db)
        else { throw MessageReceiverError.decryptionFailed }
        
        let supportedEncryptionDomains: [LibSession.Crypto.Domain] = [
            .kickedMessage
        ]
        
        try supportedEncryptionDomains
            .map { domain -> (domain: LibSession.Crypto.Domain, plaintext: Data) in
                (
                    domain,
                    try dependencies[singleton: .crypto].tryGenerate(
                        .plaintextWithMultiEncrypt(
                            ciphertext: message.ciphertext,
                            senderSessionId: senderSessionId,
                            ed25519PrivateKey: userEd25519KeyPair.secretKey,
                            domain: domain
                        )
                    )
                )
            }
            .forEach { domain, plaintext in
                switch domain {
                    case LibSession.Crypto.Domain.kickedMessage:
                        try handleGroupDelete(
                            db,
                            groupSessionId: senderSessionId,
                            plaintext: plaintext,
                            using: dependencies
                        )
                        
                    default: Log.error(.messageReceiver, "Received libSession encrypted message with unsupported domain: \(domain)")
                }
            }
    }
}

