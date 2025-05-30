// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import GRDB
import SessionUtilitiesKit

public final class DataExtractionNotification: ControlMessage {
    private enum CodingKeys: String, CodingKey {
        case kind
    }
    
    public var kind: Kind?
    
    // MARK: - Kind
    
    public enum Kind: CustomStringConvertible, Codable, Equatable {
        case screenshot
        case mediaSaved(timestamp: UInt64)  // Note: The 'timestamp' should the original message timestamp

        public var description: String {
            switch self {
                case .screenshot: return "screenshot"
                case .mediaSaved: return "mediaSaved"
            }
        }
    }

    // MARK: - Initialization
    
    public init(
        kind: Kind,
        sentTimestampMs: UInt64? = nil
    ) {
        super.init(
            sentTimestampMs: sentTimestampMs
        )
        
        self.kind = kind
    }

    // MARK: - Validation
    
    public override func isValid(isSending: Bool) -> Bool {
        guard super.isValid(isSending: isSending), let kind = kind else { return false }
        
        switch kind {
            case .screenshot: return true
            case .mediaSaved(let timestamp): return timestamp > 0
        }
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
    
    public override class func fromProto(_ proto: SNProtoContent, sender: String, using dependencies: Dependencies) -> DataExtractionNotification? {
        guard let dataExtractionNotification = proto.dataExtractionNotification else { return nil }
        let kind: Kind
        switch dataExtractionNotification.type {
        case .screenshot: kind = .screenshot
        case .mediaSaved:
            let timestamp = dataExtractionNotification.hasTimestamp ? dataExtractionNotification.timestamp : 0
            kind = .mediaSaved(timestamp: timestamp)
        }
        return DataExtractionNotification(kind: kind)
    }

    public override func toProto(_ db: Database, threadId: String) -> SNProtoContent? {
        guard let kind = kind else {
            Log.warn(.messageSender, "Couldn't construct data extraction notification proto from: \(self).")
            return nil
        }
        do {
            let dataExtractionNotification: SNProtoDataExtractionNotification.SNProtoDataExtractionNotificationBuilder
            switch kind {
            case .screenshot:
                dataExtractionNotification = SNProtoDataExtractionNotification.builder(type: .screenshot)
            case .mediaSaved(let timestamp):
                dataExtractionNotification = SNProtoDataExtractionNotification.builder(type: .mediaSaved)
                dataExtractionNotification.setTimestamp(timestamp)
            }
            let contentProto = SNProtoContent.builder()
            if let sigTimestampMs = sigTimestampMs { contentProto.setSigTimestamp(sigTimestampMs) }
            contentProto.setDataExtractionNotification(try dataExtractionNotification.build())
            // DisappearingMessagesConfiguration
            setDisappearingMessagesConfigurationIfNeeded(on: contentProto)
            return try contentProto.build()
        } catch {
            Log.warn(.messageSender, "Couldn't construct data extraction notification proto from: \(self).")
            return nil
        }
    }

    // MARK: - Description
    
    public var description: String {
        """
        DataExtractionNotification(
            kind: \(kind?.description ?? "null")
        )
        """
    }
}
