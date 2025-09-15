// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit

// MARK: - FeatureStorage

public extension FeatureStorage {
    static let pushNotificationService: FeatureConfig<Network.PushNotification.Service> = Dependencies.create(
        identifier: "pushNotificationService",
        defaultOption: .apns
    )
}

// MARK: - Network.PushNotification.Service

public extension Network.PushNotification {
    enum Service: String, Codable, CaseIterable, FeatureOption {
        case apns
        case sandbox = "apns-sandbox"   // Use for push notifications in Testnet
        
        // MARK: - Feature Option
        
        public static var defaultOption: Service = .apns
        
        public var title: String {
            switch self {
                case .apns: return "Production"
                case .sandbox: return "Sandbox"
            }
        }
        
        public var subtitle: String? {
            switch self {
                case .apns: return "This is the production push notification service."
                case .sandbox: return "This is the sandbox push notification service, it should be used when running builds from Xcode on a device to test notifications."
            }
        }
    }
}
