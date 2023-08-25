// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

public final class GroupUpdateInviteMessage: ControlMessage {
    private enum CodingKeys: String, CodingKey {
        case groupIdentityPublicKey
        case groupName
        case memberSubkey
        case memberTag
        case profile
    }
    
    public var groupIdentityPublicKey: Data
    public var groupName: String
    public var memberSubkey: Data
    public var memberTag: Data
    public var profile: VisibleMessage.VMProfile?
    
    // MARK: - Initialization
    
    public init(
        groupIdentityPublicKey: Data,
        groupName: String,
        memberSubkey: Data,
        memberTag: Data,
        profile: VisibleMessage.VMProfile? = nil,
        sentTimestamp: UInt64? = nil
    ) {
        self.groupIdentityPublicKey = groupIdentityPublicKey
        self.groupName = groupName
        self.memberSubkey = memberSubkey
        self.memberTag = memberTag
        self.profile = profile
        
        super.init(
            sentTimestamp: sentTimestamp
        )
    }
    
    // MARK: - Codable
    
    required init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        
        groupIdentityPublicKey = try container.decode(Data.self, forKey: .groupIdentityPublicKey)
        groupName = try container.decode(String.self, forKey: .groupName)
        memberSubkey = try container.decode(Data.self, forKey: .memberSubkey)
        memberTag = try container.decode(Data.self, forKey: .memberTag)
        profile = try? container.decode(VisibleMessage.VMProfile.self, forKey: .profile)
        
        try super.init(from: decoder)
    }
    
    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(groupIdentityPublicKey, forKey: .groupIdentityPublicKey)
        try container.encode(groupName, forKey: .groupName)
        try container.encode(memberSubkey, forKey: .memberSubkey)
        try container.encode(memberTag, forKey: .memberTag)
        try container.encodeIfPresent(profile, forKey: .profile)
    }

    // MARK: - Proto Conversion
    
    public override class func fromProto(_ proto: SNProtoContent, sender: String) -> GroupUpdateInviteMessage? {
        guard let groupInviteMessage = proto.dataMessage?.groupUpdateMessage?.inviteMessage else { return nil }
        
        return GroupUpdateInviteMessage(
            groupIdentityPublicKey: groupInviteMessage.groupIdentityPublicKey,
            groupName: groupInviteMessage.name,
            memberSubkey: groupInviteMessage.memberSubkey,
            memberTag: groupInviteMessage.memberTag,
            profile: VisibleMessage.VMProfile.fromProto(groupInviteMessage)
        )
    }

    public override func toProto(_ db: Database, threadId: String) -> SNProtoContent? {
        do {
            let inviteMessageBuilder: SNProtoGroupUpdateInviteMessage.SNProtoGroupUpdateInviteMessageBuilder
            
            // Profile
            if let profile = profile, let profileProto: SNProtoGroupUpdateInviteMessage = profile.toProto(groupIdentityPublicKey: groupIdentityPublicKey, name: groupName, memberSubkey: memberSubkey, memberTag: memberTag) {
                inviteMessageBuilder = profileProto.asBuilder()
            }
            else {
                inviteMessageBuilder = SNProtoGroupUpdateInviteMessage.builder(
                    groupIdentityPublicKey: groupIdentityPublicKey,
                    name: groupName,
                    memberSubkey: memberSubkey,
                    memberTag: memberTag
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
            groupIdentityPublicKey: \(groupIdentityPublicKey),
            groupName: \(groupName),
            memberSubkey: \(memberSubkey.toHexString()),
            memberTag: \(memberTag.toHexString()),
            profile: \(profile?.description ?? "null")
        )
        """
    }
}
