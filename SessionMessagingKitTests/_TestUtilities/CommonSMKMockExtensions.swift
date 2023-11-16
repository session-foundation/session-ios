// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionMessagingKit

extension SessionUtil.Config: Mocked {
    static var mock: SessionUtil.Config = .invalid
}

extension ConfigDump.Variant: Mocked {
    static var mock: ConfigDump.Variant = .userProfile
}
