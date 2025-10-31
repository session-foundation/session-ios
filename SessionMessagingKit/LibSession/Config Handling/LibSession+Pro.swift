// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit

// MARK: - Session Pro
// TODO: Implementation

public extension LibSessionCacheType {
    
    func validateProProof(for message: Message?) -> Bool {
        guard let message = message, dependencies[feature: .sessionProEnabled] else { return false }
        return dependencies[feature: .treatAllIncomingMessagesAsProMessages]
    }
    
    func validateProProof(for profile: Profile?) -> Bool {
        guard let profile = profile, dependencies[feature: .sessionProEnabled] else { return false }
        return dependencies[feature: .treatAllIncomingMessagesAsProMessages]
    }
}
