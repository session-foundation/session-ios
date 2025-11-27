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
    
    func validateSessionProState(for threadId: String?) -> Bool {
        guard let threadId = threadId, dependencies[feature: .sessionProEnabled] else { return false }
        let threadVariant = dependencies[singleton: .storage].read { db in
            try SessionThread
                .select(SessionThread.Columns.variant)
                .filter(id: threadId)
                .asRequest(of: SessionThread.Variant.self)
                .fetchOne(db)
        }
        guard threadVariant != .community else { return false }
        if threadId == dependencies[cache: .general].sessionId.hexString {
            return dependencies[feature: .mockCurrentUserSessionPro]
        } else {
            return dependencies[feature: .allUsersSessionPro]
        }
    }
    
    func shouldShowProBadge(for profile: Profile?) -> Bool {
        guard let profile = profile, dependencies[feature: .sessionProEnabled] else { return false }
        return (
            dependencies[feature: .allUsersSessionPro] &&
            dependencies[feature: .messageFeatureProBadge] ||
            (profile.showProBadge == true)
        )
    }
    
    func getCurrentUserProProof() -> String? {
        guard isSessionPro else {
            return nil
        }
        return ""
    }
    
    func getContanctProProof(for sessionId: String) -> String? {
        guard dependencies[feature: .allUsersSessionPro] else {
            return nil
        }
        return ""
    }
}
