// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit

// MARK: - Character Limits

public extension LibSession {
    static var CharacterLimit: Int { 2000 }
    static var ProCharacterLimit: Int { 10000 }
    static var PinnedConversationLimit: Int { 5 }
    
    static func numberOfCharactersLeft(for content: String, isSessionPro: Bool) -> Int {
        return ((isSessionPro ? ProCharacterLimit : CharacterLimit) - content.utf16.count)
    }
}

// MARK: - Session Pro
// TODO: Implementation

public extension LibSessionCacheType {
    var isSessionPro: Bool {
        guard dependencies[feature: .sessionProEnabled] else { return false }
        return dependencies[feature: .mockCurrentUserSessionPro]
    }
    
    func validateProProof(for message: Message?) -> Bool {
        guard let message = message, dependencies[feature: .sessionProEnabled] else { return false }
        return dependencies[feature: .allUsersSessionPro]
    }
    
    func validateProProof(for profile: Profile?) -> Bool {
        guard let profile = profile, dependencies[feature: .sessionProEnabled] else { return false }
        return dependencies[feature: .allUsersSessionPro]
    }
    
    func getProProof() -> String? {
        guard isSessionPro else {
            return nil
        }
        return ""
    }
}
