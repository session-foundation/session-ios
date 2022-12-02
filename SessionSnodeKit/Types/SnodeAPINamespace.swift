// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension SnodeAPI {
    enum Namespace: Int, Codable {
        case `default` = 0
        
        case userProfileConfig = 2
        
        case legacyClosedGroup = -10
        
        // MARK: Variables
        
        var requiresReadAuthentication: Bool {
            switch self {
                case .legacyClosedGroup: return false
                default: return true
            }
        }
        
        var requiresWriteAuthentication: Bool {
            switch self {
                // Not in use until we can batch delete and store config messages
                case .default, .legacyClosedGroup: return false
                default: return true
            }
        }
        
        var verificationString: String {
            switch self {
                case .`default`: return ""
                default: return "\(self.rawValue)"
            }
        }
    }
}
