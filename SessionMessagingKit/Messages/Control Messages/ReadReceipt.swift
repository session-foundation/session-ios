// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public final class ReadReceipt: ControlMessage {
    private enum CodingKeys: String, CodingKey {
        case timestamps
    }
    
    public var timestamps: [UInt64]?

    // MARK: - Initialization
    
    internal init(timestamps: [UInt64], sender: String? = nil) {
        super.init(sender: sender)
        
        self.timestamps = timestamps
    }

    // MARK: - Validation
    
    public override func isValid(isSending: Bool) -> Bool {
        guard super.isValid(isSending: isSending) else { return false }
        if let timestamps = timestamps, !timestamps.isEmpty { return true }
        return false
    }
    
    // MARK: - Codable
    
    required init(from decoder: Decoder) throws {
        try super.init(from: decoder)
        
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        
        timestamps = try? container.decode([UInt64].self, forKey: .timestamps)
    }
    
    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encodeIfPresent(timestamps, forKey: .timestamps)
    }

    // MARK: - Proto Conversion
    
    public override class func fromProto(_ proto: SNProtoContent, sender: String, using dependencies: Dependencies) -> ReadReceipt? {
        guard let receiptProto = proto.receiptMessage, receiptProto.type == .read else { return nil }
        let timestamps = receiptProto.timestamp
        guard !timestamps.isEmpty else { return nil }
        return ReadReceipt(timestamps: timestamps)
    }

    public override func toProto() -> SNProtoContent? {
        guard let timestamps = timestamps else {
            Log.warn(.messageSender, "Couldn't construct read receipt proto from: \(self).")
            return nil
        }
        let receiptProto = SNProtoReceiptMessage.builder(type: .read)
        receiptProto.setTimestamp(timestamps)
        let contentProto = SNProtoContent.builder()
        if let sigTimestampMs = sigTimestampMs { contentProto.setSigTimestamp(sigTimestampMs) }
        do {
            contentProto.setReceiptMessage(try receiptProto.build())
            // DisappearingMessagesConfiguration
            setDisappearingMessagesConfigurationIfNeeded(on: contentProto)
            return try contentProto.build()
        } catch {
            Log.warn(.messageSender, "Couldn't construct read receipt proto from: \(self).")
            return nil
        }
    }
    
    // MARK: - Description
    
    public var description: String {
        """
        ReadReceipt(
            timestamps: \(timestamps?.description ?? "null")
        )
        """
    }
}
