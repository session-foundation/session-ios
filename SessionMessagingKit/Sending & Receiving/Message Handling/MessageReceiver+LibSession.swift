// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

extension MessageReceiver {
    public typealias LibSessionMessageInfo = (
        senderSessionId: SessionId,
        domain: LibSession.Crypto.Domain,
        plaintext: Data
    )
    
    /// Some messages are encrypted with `libSession` and don't use Protobuf, this function decrypts those messages and
    /// routes them accordingly
    public static func decryptLibSessionMessage(
        threadId: String,
        threadVariant: SessionThread.Variant,
        message: LibSessionMessage,
        using dependencies: Dependencies
    ) throws -> [LibSessionMessageInfo] {
        guard
            let sender: String = message.sender,
            let senderSessionId: SessionId = try? SessionId(from: sender)
        else { throw MessageReceiverError.decryptionFailed }
        
        let supportedEncryptionDomains: [LibSession.Crypto.Domain] = [
            .kickedMessage
        ]
        
        return try supportedEncryptionDomains.map { domain -> LibSessionMessageInfo in
            (
                senderSessionId,
                domain,
                try dependencies[singleton: .crypto].tryGenerate(
                    .plaintextWithMultiEncrypt(
                        ciphertext: message.ciphertext,
                        senderSessionId: senderSessionId,
                        ed25519PrivateKey: dependencies[cache: .general].ed25519SecretKey,
                        domain: domain
                    )
                )
            )
        }
    }
    
    public static func handleLibSessionMessage(
        _ db: ObservingDatabase,
        threadId: String,
        threadVariant: SessionThread.Variant,
        message: LibSessionMessage,
        using dependencies: Dependencies
    ) throws {
        let result: [LibSessionMessageInfo] = try decryptLibSessionMessage(
            threadId: threadId,
            threadVariant: threadVariant,
            message: message,
            using: dependencies
        )
        
        try result.forEach { senderSessionId, domain, plaintext in
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

