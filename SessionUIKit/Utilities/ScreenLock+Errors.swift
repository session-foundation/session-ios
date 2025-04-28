// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import LocalAuthentication

public enum ScreenLockErrors {
    public static let defaultError: String = "authenticateNotAccessed".localized()
    public static let errorMap: [LAError.Code: String] = [
        .biometryNotAvailable: "lockAppEnablePasscode".localized(),
        .biometryNotEnrolled: "lockAppEnablePasscode".localized(),
        .biometryLockout: "authenticateFailedTooManyAttempts".localized(),
        .authenticationFailed: "authenticateFailed".localized(),
        .passcodeNotSet: "lockAppEnablePasscode".localized()
    ]
}
