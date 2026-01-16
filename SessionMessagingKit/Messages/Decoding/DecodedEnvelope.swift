// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionUtilitiesKit

public struct DecodedEnvelope: Sendable, Codable, Equatable {
    let success: Bool
    let envelope: Envelope
    let content: Data
    
    /// The `ed25519` public key of the sender
    ///
    /// **Note:** Messages sent to a SOGS are not encrypted so this value will be `null`
    let senderEd25519Pubkey: [UInt8]?
    let senderX25519Pubkey: [UInt8]
    let decodedPro: SessionPro.DecodedProForMessage
    let errorLenInclNullTerminator: Int
    
    /// The timestamp that the message was sent from the senders device
    ///
    /// **Note:** For a message from SOGS this value is the timestamp the message was received by the server instead of the value
    /// contained within the `Envelope`
    let sentTimestampMs: UInt64
    
    // MARK: - Initialization
    
    init(
        success: Bool,
        envelope: Envelope,
        content: Data,
        senderEd25519Pubkey: [UInt8]?,
        senderX25519Pubkey: [UInt8],
        decodedPro: SessionPro.DecodedProForMessage,
        errorLenInclNullTerminator: Int,
        sentTimestampMs: UInt64
    ) {
        self.success = success
        self.envelope = envelope
        self.content = content
        self.senderEd25519Pubkey = senderEd25519Pubkey
        self.senderX25519Pubkey = senderX25519Pubkey
        self.decodedPro = decodedPro
        self.errorLenInclNullTerminator = errorLenInclNullTerminator
        self.sentTimestampMs = sentTimestampMs
    }
    
    init(_ libSessionValue: session_protocol_decoded_envelope) {
        success = libSessionValue.success
        envelope = Envelope(libSessionValue.envelope)
        content = libSessionValue.get(\.content_plaintext)
        senderEd25519Pubkey = libSessionValue.get(\.sender_ed25519_pubkey)
        senderX25519Pubkey = libSessionValue.get(\.sender_x25519_pubkey)
        decodedPro = SessionPro.DecodedProForMessage(libSessionValue.pro)
        errorLenInclNullTerminator = libSessionValue.error_len_incl_null_terminator
        sentTimestampMs = envelope.timestampMs
    }
}

extension session_protocol_decoded_envelope: @retroactive CAccessible & CMutable {}
