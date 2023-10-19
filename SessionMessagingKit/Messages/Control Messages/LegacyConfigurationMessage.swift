// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import GRDB

public final class LegacyConfigurationMessage: ControlMessage {
    private enum CodingKeys: String, CodingKey {
        case lefacyConfigCodableId
    }
    
    /// This value shouldn't be used for any logic, it's just used to ensure this type can be uniquely encoded/decoded by
    /// the `Message.createMessageFrom(_:sender:)` function and won't collide with other message types due
    /// to having the same keys
    private let lefacyConfigCodableId: UUID = UUID()
    
    public override var isSelfSendValid: Bool { true }
    
    public override class func fromProto(_ proto: SNProtoContent, sender: String) -> LegacyConfigurationMessage? {
        guard proto.configurationMessage != nil else { return nil }
        
        return LegacyConfigurationMessage()
    }

    public override func toProto(_ db: Database, threadId: String) -> SNProtoContent? { return nil }
    public var description: String { "LegacyConfigurationMessage()" }
}
