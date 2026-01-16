// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension Network.PushNotification {
    enum ProcessResult {
        case success
        case successTooLong
        case failure
        case failureNoContent
        case legacyFailure
    }
}
