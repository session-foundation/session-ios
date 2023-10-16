// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

public final class GroupUpdateDeleteMessage: ControlMessage {
    private enum CodingKeys: String, CodingKey {
        case groupSessionId
        case encryptedMemberAuthData
    }
    
    public var groupSessionId: SessionId
    public var encryptedMemberAuthData: Data
    
    // MARK: - Initialization
    
    public init(
        groupSessionId: SessionId,
        encryptedMemberAuthData: Data,
        sentTimestamp: UInt64? = nil
    ) {
        self.groupSessionId = groupSessionId
        self.encryptedMemberAuthData = encryptedMemberAuthData
        
        super.init(
            sentTimestamp: sentTimestamp
        )
    }
    
    // MARK: - Codable
    
    required init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        
        groupSessionId = SessionId(.group, publicKey: Array(try container.decode(Data.self, forKey: .groupSessionId)))
        encryptedMemberAuthData = try container.decode(Data.self, forKey: .encryptedMemberAuthData)
        
        try super.init(from: decoder)
    }
    
    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(groupSessionId.hexString.data(using: .utf8), forKey: .groupSessionId)
        try container.encode(encryptedMemberAuthData, forKey: .encryptedMemberAuthData)
    }

    // MARK: - Proto Conversion
    
    public override class func fromProto(_ proto: SNProtoContent, sender: String) -> GroupUpdateDeleteMessage? {
        guard let groupDeleteMessage = proto.dataMessage?.groupUpdateMessage?.deleteMessage else { return nil }
        
        return GroupUpdateDeleteMessage(
            groupSessionId: SessionId(.group, publicKey: Array(groupDeleteMessage.groupSessionID)),
            encryptedMemberAuthData: groupDeleteMessage.encryptedMemberAuthData
        )
    }

    public override func toProto(_ db: Database, threadId: String) -> SNProtoContent? {
        do {
            let deleteMessageBuilder: SNProtoGroupUpdateDeleteMessage.SNProtoGroupUpdateDeleteMessageBuilder = SNProtoGroupUpdateDeleteMessage.builder(
                groupSessionID: Data(hex: groupSessionId.hexString),    // Include the prefix
                encryptedMemberAuthData: encryptedMemberAuthData
            )
            
            let groupUpdateMessage = SNProtoGroupUpdateMessage.builder()
            groupUpdateMessage.setDeleteMessage(try deleteMessageBuilder.build())
            
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
        GroupUpdateDeleteMessage(
            groupSessionId: \(groupSessionId),
            encryptedMemberAuthData: \(encryptedMemberAuthData.toHexString())
        )
        """
    }
}
