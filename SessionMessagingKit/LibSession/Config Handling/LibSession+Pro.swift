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
        if dependencies.hasSet(feature: .mockCurrentUserSessionPro) {
            return dependencies[feature: .mockCurrentUserSessionPro]
        }
        return false
    }
    
    func validateProProof(for message: Message?) -> Bool {
        if dependencies.hasSet(feature: .treatAllIncomingMessagesAsProMessages) {
            return dependencies[feature: .treatAllIncomingMessagesAsProMessages]
        }
        return false
    }
    
    func validateProProof(for profile: Profile?) -> Bool {
        guard let profile = profile else { return false }
        if dependencies.hasSet(feature: .treatAllIncomingMessagesAsProMessages) {
            return dependencies[feature: .treatAllIncomingMessagesAsProMessages]
        }
        return false
    }
    
    func getProProof() -> String? {
        guard isSessionPro else {
            return nil
        }
        return ""
    }
}
