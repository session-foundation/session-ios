// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

public final class GroupUpdateInviteMessage: ControlMessage {
    private enum CodingKeys: String, CodingKey {
        case groupSessionId
        case groupName
        case memberAuthData
        case profile
    }
    
    public var groupSessionId: SessionId
    public var groupName: String
    public var memberAuthData: Data
    public var profile: VisibleMessage.VMProfile?
    
    // MARK: - Initialization
    
    public init(
        groupSessionId: SessionId,
        groupName: String,
        memberAuthData: Data,
        profile: VisibleMessage.VMProfile? = nil,
        sentTimestamp: UInt64? = nil
    ) {
        self.groupSessionId = groupSessionId
        self.groupName = groupName
        self.memberAuthData = memberAuthData
        self.profile = profile
        
        super.init(
            sentTimestamp: sentTimestamp
        )
    }
    
    // MARK: - Codable
    
    required init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        
        groupSessionId = SessionId(.group, publicKey: Array(try container.decode(Data.self, forKey: .groupSessionId)))
        groupName = try container.decode(String.self, forKey: .groupName)
        memberAuthData = try container.decode(Data.self, forKey: .memberAuthData)
        profile = try? container.decode(VisibleMessage.VMProfile.self, forKey: .profile)
        
        try super.init(from: decoder)
    }
    
    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(groupSessionId.hexString.data(using: .utf8), forKey: .groupSessionId)
        try container.encode(groupName, forKey: .groupName)
        try container.encode(memberAuthData, forKey: .memberAuthData)
        try container.encodeIfPresent(profile, forKey: .profile)
    }

    // MARK: - Proto Conversion
    
    public override class func fromProto(_ proto: SNProtoContent, sender: String) -> GroupUpdateInviteMessage? {
        guard let groupInviteMessage = proto.dataMessage?.groupUpdateMessage?.inviteMessage else { return nil }
        
        return GroupUpdateInviteMessage(
            groupSessionId: SessionId(.group, publicKey: Array(groupInviteMessage.groupSessionID)),
            groupName: groupInviteMessage.name,
            memberAuthData: groupInviteMessage.memberAuthData,
            profile: VisibleMessage.VMProfile.fromProto(groupInviteMessage)
        )
    }

    public override func toProto(_ db: Database, threadId: String) -> SNProtoContent? {
        do {
            let inviteMessageBuilder: SNProtoGroupUpdateInviteMessage.SNProtoGroupUpdateInviteMessageBuilder
            
            // Profile
            if let profile = profile, let profileProto: SNProtoGroupUpdateInviteMessage = profile.toProto(
                groupSessionId: Data(hex: groupSessionId.hexString),    // Include the prefix,
                name: groupName,
                memberAuthData: memberAuthData
            ) {
                inviteMessageBuilder = profileProto.asBuilder()
            }
            else {
                inviteMessageBuilder = SNProtoGroupUpdateInviteMessage.builder(
                    groupSessionID: Data(hex: groupSessionId.hexString),    // Include the prefix
                    name: groupName,
                    memberAuthData: memberAuthData
                )
            }
            
            let groupUpdateMessage = SNProtoGroupUpdateMessage.builder()
            groupUpdateMessage.setInviteMessage(try inviteMessageBuilder.build())
            
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
        GroupUpdateInviteMessage(
            groupSessionId: \(groupSessionId),
            groupName: \(groupName),
            memberAuthData: \(memberAuthData.toHexString()),
            profile: \(profile?.description ?? "null")
        )
        """
    }
}
