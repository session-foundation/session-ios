// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtil
import SessionUtilitiesKit

public extension LibSession {
    // MARK: - Config
    
    enum Config {
        public enum Variant {
            case userProfile(UnsafeMutablePointer<config_object>)
            case contacts(UnsafeMutablePointer<config_object>)
            case convoInfoVolatile(UnsafeMutablePointer<config_object>)
            case userGroups(UnsafeMutablePointer<config_object>)
            
            var conf: UnsafeMutablePointer<config_object> {
                switch self {
                    case .userProfile(let value), .contacts(let value),
                        .convoInfoVolatile(let value), .userGroups(let value):
                        return value
                }
            }
        }
    }
}
