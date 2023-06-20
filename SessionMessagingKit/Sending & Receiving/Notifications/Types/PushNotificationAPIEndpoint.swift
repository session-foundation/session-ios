// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension PushNotificationAPI {
    enum Endpoint: String {
        case subscribe = "subscribe"
        case unsubscribe = "unsubscribe"
        
        // MARK: - Legacy Endpoints
        
        case legacyNotify = "notify"
        case legacyRegister = "register"
        case legacyUnregister = "unregister"
        case legacyGroupsOnlySubscribe = "register_legacy_groups_only"
        case legacyGroupSubscribe = "subscribe_closed_group"
        case legacyGroupUnsubscribe = "unsubscribe_closed_group"
        
        // MARK: - Convenience
        
        var server: String {
            switch self {
                case .legacyNotify, .legacyRegister, .legacyUnregister,
                    .legacyGroupsOnlySubscribe, .legacyGroupSubscribe, .legacyGroupUnsubscribe:
                    return PushNotificationAPI.legacyServer
                    
                default: return PushNotificationAPI.server
            }
        }
        
        var serverPublicKey: String {
            switch self {
                case .legacyNotify, .legacyRegister, .legacyUnregister,
                    .legacyGroupsOnlySubscribe, .legacyGroupSubscribe, .legacyGroupUnsubscribe:
                    return PushNotificationAPI.legacyServerPublicKey
                    
                default: return PushNotificationAPI.serverPublicKey
            }
        }
    }
}
