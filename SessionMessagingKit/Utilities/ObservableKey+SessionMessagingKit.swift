// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit

public extension ObservableKey {
    static func setting(_ key: any Setting.Key) -> ObservableKey {
        ObservableKey(key.rawValue)
    }
    static func profile(_ id: String) -> ObservableKey {
        ObservableKey("profile-\(id)")
    }
    static func contact(_ id: String) -> ObservableKey {
        ObservableKey("contact-\(id)")
    }
    static func messageReceived(threadId: String) -> ObservableKey {
        ObservableKey("messageReceived-\(threadId)")
    }
    static func unreadMessageReceived(threadId: String) -> ObservableKey {
        ObservableKey("unreadMessageReceived-\(threadId)")
    }
    static let isUsingFullAPNs: ObservableKey = "isUsingFullAPNs"
    static let unreadMessageRequestMessageReceived: ObservableKey = "unreadMessageRequestMessageReceived"
}
