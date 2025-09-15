// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionNetworkingKit
import SessionUtilitiesKit

public extension PushNotificationAPI {
    enum Endpoint: EndpointType {
        case subscribe
        case unsubscribe
        
        public static var name: String { "PushNotificationAPI.Endpoint" }
        
        public var path: String {
            switch self {
                case .subscribe: return "subscribe"
                case .unsubscribe: return "unsubscribe"
            }
        }
    }
}
