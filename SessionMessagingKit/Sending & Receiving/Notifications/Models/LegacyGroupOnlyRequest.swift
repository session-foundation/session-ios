// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

extension PushNotificationAPI {
    struct LegacyGroupOnlyRequest: Codable {
        let token: String
        let pubKey: String
        let device: String
        let legacyGroupPublicKeys: Set<String>
    }
}
