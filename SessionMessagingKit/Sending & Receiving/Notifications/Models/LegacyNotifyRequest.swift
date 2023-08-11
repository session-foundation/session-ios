// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

extension PushNotificationAPI {
    struct LegacyNotifyRequest: Codable {
        enum CodingKeys: String, CodingKey {
            case data
            case sendTo = "send_to"
        }
        
        let data: String
        let sendTo: String
    }
}
