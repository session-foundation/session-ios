// Copyright © 2026 Session Technology Foundation. All rights reserved.

import Foundation
import SessionNetworkingKit
import SessionUtilitiesKit

/// A swarm message this client positively identified as something it can't process
///
/// There are only two ways to get one of these, and the distinction from a random decryption failure is the whole point:
/// - `newerFormat`: the raw one-to-one swarm data starts with `0x00`, which no protobuf-encoded (v1) message can do, so it was
///   positively identified as a newer wire format without attempting decryption
/// - `unknownType`: the message decrypted (so the sender is authenticated) but its `Content` holds a type this client doesn't know
///
/// A message which simply fails to decrypt is still dropped silently: it can't be attributed to anyone so it could be spam,
/// corruption or an attacker, and showing anything for it would claim that someone really sent us something
public final class UnsupportedMessage: Message, NotProtoConvertible {
    private enum CodingKeys: String, CodingKey {
        case kind
        case placement
        case rawData
        case swarmPublicKey
        case namespace
        case serverTimestampMs
    }

    /// The highest top-level `Content` field number which has ever been assigned (including retired ones), any field above
    /// this is a type added after this client was built
    ///
    /// **Note:** This is deliberately a single bound rather than this client's own schema so that metadata fields added by newer
    /// clients alongside a known type (eg. `msgId = 18`) don't get mistaken for an unknown type
    static let highestKnownContentFieldNumber: Int = 18

    public static var placeholderText: String { "messageUnsupported".localized() }

    public enum Placement: String, Codable {
        /// There is no conversation to show this in (eg. a `newerFormat` message, or a sync message from our own device without
        /// a `syncTarget`) so it is only retained
        case none
        case incoming
        case outgoing
    }

    public let kind: UnsupportedMessageRecord.Kind
    public let placement: Placement
    public let rawData: Data
    public let swarmPublicKey: String
    public let namespace: Network.StorageServer.Namespace
    public let serverTimestampMs: Int64

    public override var isSelfSendValid: Bool { true }

    // MARK: - Initialization

    internal init(
        kind: UnsupportedMessageRecord.Kind,
        placement: Placement,
        rawData: Data,
        swarmPublicKey: String,
        namespace: Network.StorageServer.Namespace,
        serverHash: String,
        serverTimestampMs: Int64,
        sender: String,
        sentTimestampMs: UInt64,
        sigTimestampMs: UInt64?,
        receivedTimestampMs: UInt64
    ) {
        self.kind = kind
        self.placement = placement
        self.rawData = rawData
        self.swarmPublicKey = swarmPublicKey
        self.namespace = namespace
        self.serverTimestampMs = serverTimestampMs

        super.init(
            sentTimestampMs: sentTimestampMs,
            receivedTimestampMs: receivedTimestampMs,
            sender: sender,
            serverHash: serverHash
        )

        self.sigTimestampMs = sigTimestampMs
    }

    // MARK: - Validation

    public override func validateMessage(isSending: Bool) throws {
        try super.validateMessage(isSending: isSending)

        if rawData.isEmpty { throw MessageError.missingRequiredField("rawData") }
        if serverHash?.isEmpty != false { throw MessageError.missingRequiredField("serverHash") }
    }

    // MARK: - Codable

    required init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)

        kind = try container.decode(UnsupportedMessageRecord.Kind.self, forKey: .kind)
        placement = try container.decode(Placement.self, forKey: .placement)
        rawData = try container.decode(Data.self, forKey: .rawData)
        swarmPublicKey = try container.decode(String.self, forKey: .swarmPublicKey)
        namespace = try container.decode(Network.StorageServer.Namespace.self, forKey: .namespace)
        serverTimestampMs = try container.decode(Int64.self, forKey: .serverTimestampMs)

        try super.init(from: decoder)
    }

    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)

        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(kind, forKey: .kind)
        try container.encode(placement, forKey: .placement)
        try container.encode(rawData, forKey: .rawData)
        try container.encode(swarmPublicKey, forKey: .swarmPublicKey)
        try container.encode(namespace, forKey: .namespace)
        try container.encode(serverTimestampMs, forKey: .serverTimestampMs)
    }
}

// MARK: - Detection

internal extension UnsupportedMessage {
    /// How a protobuf field's value is encoded, taken from the low 3 bits of the field's key (the field number is the rest of the
    /// key, so this is unrelated to which field it is)
    private enum WireType: UInt64 {
        case varint = 0
        case fixed64 = 1
        case lengthDelimited = 2
        case startGroup = 3     /// Deprecated proto2 groups, which Session has never used
        case endGroup = 4
        case fixed32 = 5
    }
    
    /// Returns the field numbers of the top-level fields in a serialized protobuf message, or `nil` if the data isn't a well-formed
    /// protobuf message
    static func topLevelFieldNumbers(in data: Data) -> [Int]? {
        let bytes: [UInt8] = Array(data)
        var index: Int = 0
        var result: [Int] = []

        func readVarint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0

            while index < bytes.count && shift < 64 {
                let byte: UInt8 = bytes[index]
                index += 1
                value |= UInt64(byte & 0x7F) << shift

                guard byte & 0x80 != 0 else { return value }

                shift += 7
            }

            return nil
        }

        while index < bytes.count {
            guard let key: UInt64 = readVarint() else { return nil }

            let fieldNumber: UInt64 = (key >> 3)

            guard fieldNumber > 0 && fieldNumber <= UInt64(Int32.max) else { return nil }

            switch WireType(rawValue: key & 0x7) {
                case .varint: guard readVarint() != nil else { return nil }
                case .fixed64: index += 8
                case .lengthDelimited:
                    guard
                        let length: UInt64 = readVarint(),
                        length <= UInt64(bytes.count - index)
                    else { return nil }

                    index += Int(length)

                case .fixed32: index += 4
                case .startGroup, .endGroup, .none: return nil
            }

            guard index <= bytes.count else { return nil }

            result.append(Int(fieldNumber))
        }

        return result
    }

    static func containsUnknownContentType(_ content: Data) -> Bool {
        return (topLevelFieldNumbers(in: content) ?? []).contains { $0 > highestKnownContentFieldNumber }
    }

    /// A one-to-one swarm message whose raw data starts with `0x00` is a newer wire format (v1 data is protobuf-encoded, and no
    /// protobuf message can start with a zero byte)
    ///
    /// **Note:** This must only be applied to the one-to-one namespace, other namespaces are encrypted with symmetric keys so
    /// their data can start with any byte
    static func processedNewerFormatMessage(
        data: Data,
        origin: Message.Origin,
        using dependencies: Dependencies
    ) -> ProcessedMessage? {
        guard
            data.first == 0x00,
            case .swarm(let publicKey, .default, let serverHash, let serverTimestampMs, let serverExpirationTimestamp) = origin
        else { return nil }

        /// The sender is inside the encrypted payload so the message can't be attributed, use the current user as a stand-in so
        /// nothing downstream treats it as having come from someone else
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        let message: UnsupportedMessage = UnsupportedMessage(
            kind: .newerFormat,
            placement: .none,
            rawData: data,
            swarmPublicKey: publicKey,
            namespace: .default,
            serverHash: serverHash,
            serverTimestampMs: serverTimestampMs,
            sender: userSessionId.hexString,
            sentTimestampMs: UInt64(max(0, serverTimestampMs)),
            sigTimestampMs: nil,
            receivedTimestampMs: dependencies.networkOffsetTimestampMs()
        )

        return .standard(
            threadId: publicKey,
            threadVariant: .contact,
            messageInfo: MessageReceiveJob.Details.MessageInfo(
                message: message,
                variant: .unsupportedMessage,
                threadVariant: .contact,
                serverExpirationTimestamp: serverExpirationTimestamp,
                decodedMessage: .empty(sender: userSessionId)
            ),
            uniqueIdentifier: serverHash
        )
    }

    /// A message which decrypted but whose content can't be handled by this client and contains a type added after this client
    /// was built
    ///
    /// The second condition requires both that no type this client knows produced a valid message, and that there is positive
    /// evidence of a newer type - an empty or malformed `Content` is still just dropped
    ///
    /// **Note:** A `DataMessage` holding nothing but a `syncTarget` doesn't count as known content as that is how a sync copy of
    /// a newer type arrives (the sender adds the `syncTarget` to a `DataMessage` regardless of the message type)
    static func processedUnknownTypeMessage(
        data: Data,
        origin: Message.Origin,
        proto: SNProtoContent,
        decodedMessage: DecodedMessage,
        using dependencies: Dependencies
    ) throws -> ProcessedMessage? {
        guard
            case .swarm(let publicKey, let namespace, let serverHash, let serverTimestampMs, let serverExpirationTimestamp) = origin,
            namespace == .default || namespace == .groupMessages,
            containsUnknownContentType(decodedMessage.content),
            !hasValidKnownContent(proto, decodedMessage: decodedMessage, using: dependencies)
        else { return nil }

        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        let sender: String = decodedMessage.sender.hexString
        let isFromCurrentUser: Bool = (decodedMessage.sender == userSessionId)
        let threadId: String
        let threadVariant: SessionThread.Variant
        let placement: Placement

        switch (namespace, isFromCurrentUser) {
            case (.groupMessages, _):
                threadId = publicKey
                threadVariant = .group
                placement = (isFromCurrentUser ? .outgoing : .incoming)

            case (_, false):
                threadId = sender
                threadVariant = .contact
                placement = .incoming

            case (_, true):
                threadVariant = .contact

                switch proto.dataMessage?.syncTarget.flatMap({ try? SessionId(from: $0) }) {
                    case .some(let syncTarget) where syncTarget.prefix == .standard:
                        threadId = syncTarget.hexString
                        placement = .outgoing

                    default:
                        threadId = publicKey
                        placement = .none
                }
        }

        /// Don't process messages from blocked senders
        guard
            isFromCurrentUser ||
            dependencies.mutate(cache: .libSession, { cache in !cache.isContactBlocked(contactId: sender) })
        else { throw MessageError.senderBlocked }

        let message: UnsupportedMessage = UnsupportedMessage(
            kind: .unknownType,
            placement: placement,
            rawData: data,
            swarmPublicKey: publicKey,
            namespace: namespace,
            serverHash: serverHash,
            serverTimestampMs: serverTimestampMs,
            sender: sender,
            sentTimestampMs: decodedMessage.sentTimestampMs,
            sigTimestampMs: (proto.hasSigTimestamp ? proto.sigTimestamp : nil),
            receivedTimestampMs: dependencies.networkOffsetTimestampMs()
        )

        /// The disappearing messages settings are known fields even when the type isn't so they still apply
        message.attachDisappearingMessagesConfiguration(from: proto)
        try message.validateMessage(isSending: false)

        return .standard(
            threadId: threadId,
            threadVariant: threadVariant,
            messageInfo: MessageReceiveJob.Details.MessageInfo(
                message: message,
                variant: .unsupportedMessage,
                threadVariant: threadVariant,
                serverExpirationTimestamp: serverExpirationTimestamp,
                decodedMessage: decodedMessage
            ),
            uniqueIdentifier: serverHash
        )
    }

    private static func hasValidKnownContent(
        _ proto: SNProtoContent,
        decodedMessage: DecodedMessage,
        using dependencies: Dependencies
    ) -> Bool {
        guard let message: Message = try? Message.createMessageFrom(proto, decodedMessage: decodedMessage, using: dependencies) else {
            return false
        }

        message.sender = decodedMessage.sender.hexString
        message.sentTimestampMs = decodedMessage.sentTimestampMs
        message.sigTimestampMs = (proto.hasSigTimestamp ? proto.sigTimestamp : nil)
        message.receivedTimestampMs = dependencies.networkOffsetTimestampMs()

        return ((try? message.validateMessage(isSending: false)) != nil)
    }
}
