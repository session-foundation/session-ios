// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit

// MARK: - KeychainStorage

public extension KeychainStorage.DataKey { static let pushNotificationEncryptionKey: Self = "PNEncryptionKeyKey" }

// MARK: - Log.Category

public extension Log.Category {
    static let pushNotificationAPI: Log.Category = .create("PushNotificationAPI", defaultLevel: .info)
}

// MARK: - Network.PushNotification

public extension Network {
    enum PushNotification {
        internal static let encryptionKeyLength: Int = 32
        internal static let maxRetryCount: Int = 4
        public static let tokenExpirationInterval: TimeInterval = (12 * 60 * 60)
        
        internal static let server: String = "https://push.getsession.org"
        internal static let serverPublicKey = "d7557fe563e2610de876c0ac7341b62f3c82d5eea4b62c702392ea4368f51b3b"
    }
}
