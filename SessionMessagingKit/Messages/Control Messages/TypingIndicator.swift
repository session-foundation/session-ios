// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public final class TypingIndicator: ControlMessage {
    private enum CodingKeys: String, CodingKey {
        case kind
    }
    
    public var kind: Kind?

    public override var ttl: UInt64 { 20 * 1000 }

    // MARK: - Kind
    
    public enum Kind: Int, Codable, CustomStringConvertible {
        case started, stopped

        static func fromProto(_ proto: SNProtoTypingMessage.SNProtoTypingMessageAction) -> Kind {
            switch proto {
                case .started: return .started
                case .stopped: return .stopped
            }
        }

        func toProto() -> SNProtoTypingMessage.SNProtoTypingMessageAction {
            switch self {
                case .started: return .started
                case .stopped: return .stopped
            }
        }
        
        // stringlint:ignore_contents
        public var description: String {
            switch self {
                case .started: return "started"
                case .stopped: return "stopped"
            }
        }
    }

    // MARK: - Validation
    
    public override func validateMessage(isSending: Bool) throws {
        try super.validateMessage(isSending: isSending)
        
        if kind == nil { throw MessageError.missingRequiredField("kind") }
    }

    // MARK: - Initialization

    internal init(kind: Kind, sender: String? = nil) {
        super.init(sender: sender)
        
        self.kind = kind
    }
    
    // MARK: - Codable
    
    required init(from decoder: Decoder) throws {
        try super.init(from: decoder)
        
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        
        kind = try? container.decode(Kind.self, forKey: .kind)
    }
    
    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encodeIfPresent(kind, forKey: .kind)
    }

    // MARK: - Proto Conversion
    
    public override class func fromProto(_ proto: SNProtoContent, sender: String, using dependencies: Dependencies) -> TypingIndicator? {
        guard let typingIndicatorProto = proto.typingMessage else { return nil }
        let kind = Kind.fromProto(typingIndicatorProto.action)
        return TypingIndicator(kind: kind)
    }

    public override func toProto() -> SNProtoContent? {
        guard let timestampMs = sentTimestampMs, let kind = kind else {
            Log.warn(.messageSender, "Couldn't construct typing indicator proto from: \(self).")
            return nil
        }
        let typingIndicatorProto = SNProtoTypingMessage.builder(timestamp: timestampMs, action: kind.toProto())
        let contentProto = SNProtoContent.builder()
        if let sigTimestampMs = sigTimestampMs { contentProto.setSigTimestamp(sigTimestampMs) }
        do {
            contentProto.setTypingMessage(try typingIndicatorProto.build())
            return try contentProto.build()
        } catch {
            Log.warn(.messageSender, "Couldn't construct typing indicator proto from: \(self).")
            return nil
        }
    }
    
    // MARK: - Description
    
    public var description: String {
        """
        TypingIndicator(
            kind: \(kind?.description ?? "null")
        )
        """
    }
}
