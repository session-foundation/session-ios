// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

public final class LegacyConfigurationMessage: ControlMessage {
    public override var isSelfSendValid: Bool { true }
    
    public override class func fromProto(_ proto: SNProtoContent, sender: String) -> LegacyConfigurationMessage? {
        guard proto.configurationMessage != nil else { return nil }
        
        return LegacyConfigurationMessage()
    }

    public override func toProto(_ db: Database, threadId: String) -> SNProtoContent? { return nil }
    public var description: String { "LegacyConfigurationMessage()" }
}
