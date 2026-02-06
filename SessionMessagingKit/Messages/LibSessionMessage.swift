// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public final class LibSessionMessage: Message, NotProtoConvertible {
    private enum CodingKeys: String, CodingKey {
        case ciphertext
    }
    
    public var ciphertext: Data
    
    // MARK: - Validation
    
    public override func validateMessage(isSending: Bool) throws {
        try super.validateMessage(isSending: isSending)
        
        if ciphertext.isEmpty { throw MessageError.missingRequiredField("ciphertext") }
    }

    // MARK: - Initialization
    
    internal init(ciphertext: Data, sender: String? = nil) {
        self.ciphertext = ciphertext
        
        super.init(sender: sender)
    }
    
    // MARK: - Codable
    
    required init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        
        ciphertext = try container.decode(Data.self, forKey: .ciphertext)
        
        try super.init(from: decoder)
    }
    
    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(ciphertext, forKey: .ciphertext)
    }
}

// MARK: - Message types

public extension LibSessionMessage {
    // MARK: - groupKicked
    
    static func groupKicked(memberId: String, groupKeysGen: Int) throws -> (SessionId, Data) {
        guard
            let sessionId: SessionId = try? SessionId(from: memberId),
            let groupKeysGenData: Data = "\(groupKeysGen)".data(using: .ascii)
        else { throw MessageError.invalidMessage("Unable to generate group kicked message") }
        
        return (sessionId, Data(sessionId.publicKey.appending(contentsOf: Array(groupKeysGenData))))
    }
    
    static func groupKicked(plaintext: Data) throws -> (memberId: SessionId, groupKeysGen: Int) {
        /// Count of the sessionId excluding the prefix
        let pubkeyBytesCount: Int = (SessionId.byteCount - 1)
        
        guard
            plaintext.count > pubkeyBytesCount,
            let currentGenString: String = String(
                data: Data(plaintext[pubkeyBytesCount...]),
                encoding: .ascii
            ),
            let currentGen: Int = Int(currentGenString, radix: 10)
        else { throw MessageError.decodingFailed }
        
        return (SessionId(.standard, publicKey: Array(plaintext[0..<pubkeyBytesCount])), currentGen)
    }
    
    static func validateGroupKickedMessage(
        plaintext: Data,
        userSessionId: SessionId,
        groupSessionId: SessionId,
        using dependencies: Dependencies
    ) throws {
        /// Ignore the message if the `memberSessionIds` doesn't contain the current users session id,
        /// it was sent before the user joined the group or if the `adminSignature` isn't valid
        guard let (memberId, keysGen): (SessionId, Int) = try? LibSessionMessage.groupKicked(plaintext: plaintext) else {
            throw MessageError.invalidMessage("Could not process as group kicked message")
        }
        
        guard
            let currentKeysGen: Int = try? LibSession.currentGeneration(
                groupSessionId: groupSessionId,
                using: dependencies
            ),
            memberId == userSessionId,
            keysGen >= currentKeysGen
        else { throw MessageError.ignorableMessage }
    }
}
