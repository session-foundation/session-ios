// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension Network {
    enum SOGS {
        public static let legacyDefaultServerIP = "116.203.70.33"
        public static let defaultServer = "https://open.getsession.org"
        public static let defaultServerPublicKey = "a03c383cf63c3c4efe67acc52112a6dd734b3a946b9545f488aaa93da7991238"
        public static let validTimestampVarianceThreshold: TimeInterval = (6 * 60 * 60)
        internal static let maxInactivityPeriodForPolling: TimeInterval = (14 * 24 * 60 * 60)

        public static let workQueue = DispatchQueue(label: "SOGS.workQueue", qos: .userInitiated) // It's important that this is a serial queue
    }
}
