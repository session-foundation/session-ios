// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

public final class GroupUpdatePromoteMessage: ControlMessage {
    private enum CodingKeys: String, CodingKey {
        case memberPublicKey
        case encryptedGroupIdentityPrivateKey
    }
    
    public var memberPublicKey: Data
    public var encryptedGroupIdentityPrivateKey: Data
    
    // MARK: - Initialization
    
    public init(
        memberPublicKey: Data,
        encryptedGroupIdentityPrivateKey: Data,
        sentTimestamp: UInt64? = nil
    ) {
        self.memberPublicKey = memberPublicKey
        self.encryptedGroupIdentityPrivateKey = encryptedGroupIdentityPrivateKey
        
        super.init(
            sentTimestamp: sentTimestamp
        )
    }
    
    // MARK: - Codable
    
    required init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        
        memberPublicKey = try container.decode(Data.self, forKey: .memberPublicKey)
        encryptedGroupIdentityPrivateKey = try container.decode(Data.self, forKey: .encryptedGroupIdentityPrivateKey)
        
        try super.init(from: decoder)
    }
    
    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(memberPublicKey, forKey: .memberPublicKey)
        try container.encode(encryptedGroupIdentityPrivateKey, forKey: .encryptedGroupIdentityPrivateKey)
    }

    // MARK: - Proto Conversion
    
    public override class func fromProto(_ proto: SNProtoContent, sender: String) -> GroupUpdatePromoteMessage? {
        guard let groupPromoteMessage = proto.dataMessage?.groupUpdateMessage?.promoteMessage else { return nil }
        
        return GroupUpdatePromoteMessage(
            memberPublicKey: groupPromoteMessage.memberPublicKey,
            encryptedGroupIdentityPrivateKey: groupPromoteMessage.encryptedGroupIdentityPrivateKey
        )
    }

    public override func toProto(_ db: Database, threadId: String) -> SNProtoContent? {
        do {
            let promoteMessageBuilder: SNProtoGroupUpdatePromoteMessage.SNProtoGroupUpdatePromoteMessageBuilder = SNProtoGroupUpdatePromoteMessage.builder(
                memberPublicKey: memberPublicKey,
                encryptedGroupIdentityPrivateKey: encryptedGroupIdentityPrivateKey
            )
            
            let groupUpdateMessage = SNProtoGroupUpdateMessage.builder()
            groupUpdateMessage.setPromoteMessage(try promoteMessageBuilder.build())
            
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
        GroupUpdatePromoteMessage(
            memberPublicKey: \(memberPublicKey.toHexString()),
            encryptedGroupIdentityPrivateKey: \(encryptedGroupIdentityPrivateKey.toHexString())
        )
        """
    }
}
