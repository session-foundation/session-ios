// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public final class LibSessionMessage: Message, NotProtoConvertible {
    private enum CodingKeys: String, CodingKey {
        case ciphertext
        case serverTimestampMs
    }

    public var ciphertext: Data

    /// The timestamp (ms) at which the message was stored on the swarm. Used to reject stale/replayed control messages
    /// (eg. a `groupKicked` message which predates the user's current group membership). Optional as it's only populated
    /// for messages received from a swarm origin - when `nil` any freshness check fails-safe (ie. proceeds as if fresh)
    public var serverTimestampMs: Int64?
    
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
        serverTimestampMs = try container.decodeIfPresent(Int64.self, forKey: .serverTimestampMs)

        try super.init(from: decoder)
    }
    
    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(ciphertext, forKey: .ciphertext)
        try container.encodeIfPresent(serverTimestampMs, forKey: .serverTimestampMs)
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
        serverTimestampMs: Int64?,
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

        /// Reject stale/replayed kick messages which predate the user's _current_ membership of the group
        ///
        /// The `keysGen >= currentKeysGen` check above is only a generation _floor_ and isn't sufficient on its own: after a
        /// kick+re-invite a non-admin member's `groupKeys` starts empty at generation 0 until a poll merges the real keys, so
        /// during that window a replayed old "kicked at gen N" message would satisfy `N >= 0` and wrongly wipe the group
        /// state again. The kick is delivered via the admin-only `revokedRetrievableGroupMessages` namespace so its swarm
        /// `serverTimestampMs` is trustworthy, and a genuine _current_ kick is always sent after the member's most recent
        /// (re-)join - so we can safely ignore any kick whose swarm timestamp predates the stored `joinedAt`.
        ///
        /// **Note:** We only reject when we _positively_ know the message is stale (both timestamps present and the message is
        /// strictly older). If either value is missing we fall through and apply the kick, since failing to apply a genuine kick
        /// (leaving an ex-member with group access) is far worse than a rare failure to reject a replay
        let joinedAtMs: Int64? = dependencies
            .mutate(cache: .libSession) { cache in
                cache.groupInfo(for: [groupSessionId.hexString]).first.flatMap { $0 }?.joinedAt
            }
            .map { Int64($0 * 1000) }

        if
            let joinedAtMs: Int64 = joinedAtMs,
            let serverTimestampMs: Int64 = serverTimestampMs,
            joinedAtMs > 0,
            serverTimestampMs > 0,
            serverTimestampMs < joinedAtMs
        {
            throw MessageError.ignorableMessage
        }
    }
}
