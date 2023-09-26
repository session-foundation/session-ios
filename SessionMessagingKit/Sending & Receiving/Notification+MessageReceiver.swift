// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public extension Notification.Name {
    static let missedCall = Notification.Name("missedCall")
}

public extension Notification.Key {
    static let senderId = Notification.Key("senderId")
}
