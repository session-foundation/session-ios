// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionMessagingKit

extension SessionUtil.Config: Mocked {
    static var mockValue: SessionUtil.Config = {
        var config: config_object = config_object()
        
        return .object(&config)
    }()
}

extension ConfigDump.Variant: Mocked {
    static var mockValue: ConfigDump.Variant = .userProfile
}
