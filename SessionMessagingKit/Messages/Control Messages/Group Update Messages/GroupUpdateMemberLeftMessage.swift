// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

public final class GroupUpdateMemberLeftMessage: ControlMessage {
    // MARK: - Proto Conversion
    
    public override class func fromProto(_ proto: SNProtoContent, sender: String) -> GroupUpdateMemberLeftMessage? {
        guard let groupMemberLeftMessage = proto.dataMessage?.groupUpdateMessage?.memberLeftMessage else { return nil }
        
        return GroupUpdateMemberLeftMessage()
    }

    public override func toProto(_ db: Database, threadId: String) -> SNProtoContent? {
        do {
            let memberLeftMessageBuilder: SNProtoGroupUpdateMemberLeftMessage.SNProtoGroupUpdateMemberLeftMessageBuilder = SNProtoGroupUpdateMemberLeftMessage.builder()
            
            let dataMessage = SNProtoDataMessage.builder()
            dataMessage.setMemberLeftMessage(try memberLeftMessageBuilder.build())
            
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
        GroupUpdateMemberLeftMessage()
        """
    }
}
