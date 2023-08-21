// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

extension PushNotificationAPI {
    enum Service: String, Codable {
        case apns
        case sandbox = "apns-sandbox"   // Use for push notifications in Testnet
    }
}
