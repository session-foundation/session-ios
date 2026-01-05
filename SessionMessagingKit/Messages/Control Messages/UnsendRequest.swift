// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public final class UnsendRequest: ControlMessage {
    private enum CodingKeys: String, CodingKey {
        case timestamp
        case author
    }
    
    public var timestamp: UInt64?
    public var author: String?
    
    public override var isSelfSendValid: Bool { true }
    
    // MARK: - Validation
    
    public override func validateMessage(isSending: Bool) throws {
        try super.validateMessage(isSending: isSending)
        
        if (timestamp ?? 0) == 0 { throw MessageError.missingRequiredField("timestamp") }
        if author?.isEmpty != false { throw MessageError.missingRequiredField("author") }
    }
    
    // MARK: - Initialization
    
    public init(timestamp: UInt64, author: String, sender: String? = nil) {
        super.init(sender: sender)
        
        self.timestamp = timestamp
        self.author = author
    }
    
    // MARK: - Codable
    
    required init(from decoder: Decoder) throws {
        try super.init(from: decoder)
        
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        
        timestamp = try? container.decode(UInt64.self, forKey: .timestamp)
        author = try? container.decode(String.self, forKey: .author)
    }
    
    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encodeIfPresent(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(author, forKey: .author)
    }
    
    // MARK: - Proto Conversion
    
    public override class func fromProto(_ proto: SNProtoContent, sender: String, using dependencies: Dependencies) -> UnsendRequest? {
        guard let unsendRequestProto = proto.unsendRequest else { return nil }
        let timestamp = unsendRequestProto.timestamp
        let author = unsendRequestProto.author
        return UnsendRequest(timestamp: timestamp, author: author)
    }

    public override func toProto() -> SNProtoContent? {
        guard let timestamp = timestamp, let author = author else {
            Log.warn(.messageSender, "Couldn't construct unsend request proto from: \(self).")
            return nil
        }
        let unsendRequestProto = SNProtoUnsendRequest.builder(timestamp: timestamp, author: author)
        let contentProto = SNProtoContent.builder()
        if let sigTimestampMs = sigTimestampMs { contentProto.setSigTimestamp(sigTimestampMs) }
        do {
            contentProto.setUnsendRequest(try unsendRequestProto.build())
            // DisappearingMessagesConfiguration
            setDisappearingMessagesConfigurationIfNeeded(on: contentProto)
            return try contentProto.build()
        } catch {
            Log.warn(.messageSender, "Couldn't construct unsend request proto from: \(self).")
            return nil
        }
    }
    
    // MARK: - Description
    
    public var description: String {
        """
        UnsendRequest(
            timestamp: \(timestamp?.description ?? "null")
            author: \(author?.description ?? "null")
        )
        """
    }
}
