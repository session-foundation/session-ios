// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

extension PushNotificationAPI {
    struct LegacyGroupRequest: Codable {
        let pubKey: String
        let closedGroupPublicKey: String
    }
}
