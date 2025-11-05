// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionUtilitiesKit

public struct DecodedMessage: Codable, Equatable {
    static let empty: DecodedMessage = DecodedMessage(
        content: Data(),
        sender: .invalid,
        decodedEnvelope: nil,
        sentTimestampMs: 0
    )
    
    public let content: Data
    public let sender: SessionId
    
    /// The decoded envelope data
    ///
    /// **Note:** For legacy SOGS messages this value will be `null`
    public let decodedEnvelope: DecodedEnvelope?
    
    /// The timestamp that the message was sent from the senders device
    ///
    /// **Note:** For a message from SOGS this value is the timestamp the message was received by the server instead of the value
    /// contained within the `Envelope`
    public let sentTimestampMs: UInt64
    
    // MARK: - Convenience forwarded access
    
    var senderEd25519Pubkey: [UInt8]? { decodedEnvelope?.senderEd25519Pubkey }
    var senderX25519Pubkey: [UInt8]? { decodedEnvelope?.senderX25519Pubkey }
    var decodedPro: SessionPro.DecodedProForMessage? { decodedEnvelope?.decodedPro }
    
    // MARK: - Initialization
    
    init(
        content: Data,
        sender: SessionId,
        decodedEnvelope: DecodedEnvelope?,
        sentTimestampMs: UInt64
    ) {
        self.content = content
        self.sender = sender
        self.decodedEnvelope = decodedEnvelope
        self.sentTimestampMs = sentTimestampMs
    }
    
    init(decodedValue: session_protocol_decoded_envelope) {
        let decodedEnvelope: DecodedEnvelope = DecodedEnvelope(decodedValue)
        
        self = DecodedMessage(
            content: decodedEnvelope.content,
            sender: SessionId(.standard, publicKey: decodedEnvelope.senderX25519Pubkey),
            decodedEnvelope: decodedEnvelope,
            sentTimestampMs: decodedEnvelope.envelope.timestampMs
        )
    }
    
    init(
        decodedValue: session_protocol_decoded_community_message,
        sender: String,
        posted: TimeInterval
    ) throws {
        let content: Data = decodedValue.get(\.content_plaintext)
        let senderSessionId: SessionId = try SessionId(from: sender)
        
        self = DecodedMessage(
            content: content.prefix(decodedValue.content_plaintext_unpadded_size),
            sender: senderSessionId,
            decodedEnvelope: {
                guard decodedValue.has_envelope else { return nil }
                
                return DecodedEnvelope(
                    success: decodedValue.success,
                    envelope: Envelope(decodedValue.envelope),
                    content: content,
                    senderEd25519Pubkey: nil,    /// SOGS doesn't include the senders `ed25519` key
                    senderX25519Pubkey: senderSessionId.publicKey,
                    decodedPro: SessionPro.DecodedProForMessage(decodedValue.pro),
                    errorLenInclNullTerminator: decodedValue.error_len_incl_null_terminator,
                    sentTimestampMs: UInt64(floor(posted * 1000))
                )
            }(),
            sentTimestampMs: UInt64(floor(posted * 1000))
        )
    }
    
    // MARK: - Functions
    
    public func decodeProtoContent() throws -> SNProtoContent {
        return try Result(catching: { try SNProtoContent.parseData(content) })
            .onFailure { Log.error(.messageReceiver, "Couldn't parse proto due to error: \($0).") }
            .get()
    }
}

extension session_protocol_decoded_community_message: @retroactive CAccessible {}
