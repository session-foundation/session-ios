// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension PushNotificationAPI {
    enum ProcessResult {
        case success
        case successTooLong
        case failure
        case failureNoContent
        case legacySuccess
        case legacyFailure
        case legacyForceSilent
    }
}
