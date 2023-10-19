// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

public final class GroupUpdateInviteResponseMessage: ControlMessage {
    private enum CodingKeys: String, CodingKey {
        case isApproved
        case profile
    }
    
    public var isApproved: Bool
    public var profile: VisibleMessage.VMProfile?
    
    override public var processWithBlockedSender: Bool { true }
    
    // MARK: - Initialization
    
    public init(
        isApproved: Bool,
        profile: VisibleMessage.VMProfile? = nil,
        sentTimestamp: UInt64? = nil
    ) {
        self.isApproved = isApproved
        self.profile = profile
        
        super.init(
            sentTimestamp: sentTimestamp
        )
    }
    
    // MARK: - Codable
    
    required init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        
        isApproved = try container.decode(Bool.self, forKey: .isApproved)
        profile = try? container.decode(VisibleMessage.VMProfile.self, forKey: .profile)
        
        try super.init(from: decoder)
    }
    
    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(isApproved, forKey: .isApproved)
        try container.encodeIfPresent(profile, forKey: .profile)
    }

    // MARK: - Proto Conversion
    
    public override class func fromProto(_ proto: SNProtoContent, sender: String) -> GroupUpdateInviteResponseMessage? {
        guard let groupInviteResponseMessage = proto.dataMessage?.groupUpdateMessage?.inviteResponse else { return nil }
        
        return GroupUpdateInviteResponseMessage(
            isApproved: groupInviteResponseMessage.isApproved,
            profile: VisibleMessage.VMProfile.fromProto(groupInviteResponseMessage)
        )
    }

    public override func toProto(_ db: Database, threadId: String) -> SNProtoContent? {
        do {
            let inviteResponseMessageBuilder: SNProtoGroupUpdateInviteResponseMessage.SNProtoGroupUpdateInviteResponseMessageBuilder
            
            // Profile
            if let profile = profile, let profileProto: SNProtoGroupUpdateInviteResponseMessage = profile.toProto(isApproved: isApproved) {
                inviteResponseMessageBuilder = profileProto.asBuilder()
            }
            else {
                inviteResponseMessageBuilder = SNProtoGroupUpdateInviteResponseMessage.builder(
                    isApproved: isApproved
                )
            }
            
            let groupUpdateMessage = SNProtoGroupUpdateMessage.builder()
            groupUpdateMessage.setInviteResponse(try inviteResponseMessageBuilder.build())
            
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
        GroupUpdateInviteResponseMessage(
            isApproved: \(isApproved),
            profile: \(profile?.description ?? "null")
        )
        """
    }
}
