// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

public final class GroupUpdateDeleteMemberContentMessage: ControlMessage {
    private enum CodingKeys: String, CodingKey {
        case memberPublicKeys
    }
    
    public var memberPublicKeys: [Data]
    
    override public var processWithBlockedSender: Bool { true }
    
    // MARK: - Initialization
    
    public init(
        memberPublicKeys: [Data],
        sentTimestamp: UInt64? = nil
    ) {
        self.memberPublicKeys = memberPublicKeys
        
        super.init(
            sentTimestamp: sentTimestamp
        )
    }
    
    // MARK: - Codable
    
    required init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        
        memberPublicKeys = try container.decode([Data].self, forKey: .memberPublicKeys)
        
        try super.init(from: decoder)
    }
    
    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(memberPublicKeys, forKey: .memberPublicKeys)
    }

    // MARK: - Proto Conversion
    
    public override class func fromProto(_ proto: SNProtoContent, sender: String) -> GroupUpdateDeleteMemberContentMessage? {
        guard let groupDeleteMemberContentMessage = proto.dataMessage?.groupUpdateMessage?.deleteMemberContent else { return nil }
        
        return GroupUpdateDeleteMemberContentMessage(
            memberPublicKeys: groupDeleteMemberContentMessage.memberPublicKeys
        )
    }

    public override func toProto(_ db: Database, threadId: String) -> SNProtoContent? {
        do {
            let deleteMemberContentMessageBuilder: SNProtoGroupUpdateDeleteMemberContentMessage.SNProtoGroupUpdateDeleteMemberContentMessageBuilder = SNProtoGroupUpdateDeleteMemberContentMessage.builder()
            deleteMemberContentMessageBuilder.setMemberPublicKeys(memberPublicKeys)
            
            let groupUpdateMessage = SNProtoGroupUpdateMessage.builder()
            groupUpdateMessage.setDeleteMemberContent(try deleteMemberContentMessageBuilder.build())
            
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
        GroupUpdateDeleteMemberContentMessage(
            memberPublicKeys: \(memberPublicKeys.map { $0.toHexString() })
        )
        """
    }
}
