// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit

public extension Network.PushNotification {
    enum Endpoint: EndpointType {
        case subscribe
        case unsubscribe
        
        public static var name: String { "PushNotification.Endpoint" }
        
        public var path: String {
            switch self {
                case .subscribe: return "subscribe"
                case .unsubscribe: return "unsubscribe"
            }
        }
    }
}
