// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

public final class GroupUpdatePromotionResponseMessage: ControlMessage {
    private enum CodingKeys: String, CodingKey {
        case encryptedMemberSessionId
    }
    
    public var encryptedMemberSessionId: Data
    
    // MARK: - Initialization
    
    public init(
        encryptedMemberSessionId: Data,
        sentTimestamp: UInt64? = nil
    ) {
        self.encryptedMemberSessionId = encryptedMemberSessionId
        
        super.init(
            sentTimestamp: sentTimestamp
        )
    }
    
    // MARK: - Codable
    
    required init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        
        encryptedMemberSessionId = try container.decode(Data.self, forKey: .encryptedMemberSessionId)
        
        try super.init(from: decoder)
    }
    
    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(encryptedMemberSessionId, forKey: .encryptedMemberSessionId)
    }

    // MARK: - Proto Conversion
    
    public override class func fromProto(_ proto: SNProtoContent, sender: String) -> GroupUpdatePromotionResponseMessage? {
        guard let groupPromotionResponseMessage = proto.dataMessage?.groupUpdateMessage?.promotionResponse else { return nil }
        
        return GroupUpdatePromotionResponseMessage(
            encryptedMemberSessionId: groupPromotionResponseMessage.encryptedMemberSessionId
        )
    }

    public override func toProto(_ db: Database, threadId: String) -> SNProtoContent? {
        do {
            let promotionResponseMessageBuilder: SNProtoGroupUpdatePromotionResponseMessage.SNProtoGroupUpdatePromotionResponseMessageBuilder = SNProtoGroupUpdatePromotionResponseMessage.builder(
                encryptedMemberSessionID: encryptedMemberSessionId
            )
            
            let groupUpdateMessage = SNProtoGroupUpdateMessage.builder()
            groupUpdateMessage.setPromotionResponse(try promotionResponseMessageBuilder.build())
            
            let dataMessage = SNProtoDataMessage.builder()
            dataMessage.setGroupUpdateMessage(try groupUpdateMessage.build())
            
            let contentProto = SNProtoContent.builder()
            contentProto.setDataMessage(try dataMessage.build())
            return try contentProto.build()
        } catch {
            SNLog("Couldn't construct data extraction notification proto from: \(self).")
            return nil
        }
    }

    // MARK: - Description
    
    public var description: String {
        """
        GroupUpdatePromotionResponseMessage(
            encryptedMemberSessionId: \(encryptedMemberSessionId.toHexString())
        )
        """
    }
}
