// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

public final class SharedConfigMessage: ControlMessage {
    private enum CodingKeys: String, CodingKey {
        case kind
        case seqNo
        case data
    }
    
    public var kind: Kind
    public var seqNo: Int64
    public var data: Data
    
    public override var isSelfSendValid: Bool { true }
    
    // MARK: - Kind
    
    public enum Kind: CustomStringConvertible, Codable {
        case userProfile

        public var description: String {
            switch self {
                case .userProfile: return "userProfile"
            }
        }
    }

    // MARK: - Initialization
    
    public init(
        kind: Kind,
        seqNo: Int64,
        data: Data
    ) {
        self.kind = kind
        self.seqNo = seqNo
        self.data = data
        
        super.init()
    }
    
    // MARK: - Codable
    
    required init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        
        kind = try container.decode(Kind.self, forKey: .kind)
        seqNo = try container.decode(Int64.self, forKey: .seqNo)
        data = try container.decode(Data.self, forKey: .data)
        
        try super.init(from: decoder)
    }
    
    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(kind, forKey: .kind)
        try container.encode(seqNo, forKey: .seqNo)
        try container.encode(data, forKey: .data)
    }

    // MARK: - Proto Conversion
    
    public override class func fromProto(_ proto: SNProtoContent, sender: String) -> SharedConfigMessage? {
        guard let sharedConfigMessage = proto.sharedConfigMessage else { return nil }
        
        return SharedConfigMessage(
            kind: {
                switch sharedConfigMessage.kind {
                    case .userProfile: return .userProfile
                }
            }(),
            seqNo: sharedConfigMessage.seqno,
            data: sharedConfigMessage.data
        )
    }

    public override func toProto(_ db: Database) -> SNProtoContent? {
        do {
            let sharedConfigMessage: SNProtoSharedConfigMessage.SNProtoSharedConfigMessageBuilder = SNProtoSharedConfigMessage.builder(
                kind: {
                    switch self.kind {
                        case .userProfile: return .userProfile
                    }
                }(),
                seqno: self.seqNo,
                data: self.data
            )
            
            let contentProto = SNProtoContent.builder()
            contentProto.setSharedConfigMessage(try sharedConfigMessage.build())
            return try contentProto.build()
        } catch {
            SNLog("Couldn't construct data extraction notification proto from: \(self).")
            return nil
        }
    }

    // MARK: - Description
    
    public var description: String {
        """
        SharedConfigMessage(
            kind: \(kind.description),
            seqNo: \(seqNo),
            data: \(data.count) bytes
        )
        """
    }
}

// MARK: - Convenience

public extension SharedConfigMessage.Kind {
    var configDumpVariant: ConfigDump.Variant {
        switch self {
            case .userProfile: return .userProfile
        }
    }
}
