// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionSnodeKit

extension PushNotificationAPI {
    struct LegacyUnsubscribeRequest: Codable {
        private let token: String
        
        init(token: String) {
            self.token = token
        }
    }
}
