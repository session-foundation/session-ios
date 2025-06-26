// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit

// MARK: - Character Limits

public extension LibSession {
    static var CharacterLimit: Int { 2000 }
    static var ProCharacterLimit: Int { 10000 }
    
    static func numberOfCharactersLeft(for content: String, isSessionPro: Bool) -> Int {
        return ((isSessionPro ? ProCharacterLimit : CharacterLimit) - content.count)
    }
}

// MARK: - Session Pro

public extension LibSessionCacheType {
    var isSessionPro: Bool { return dependencies[feature: .mockCurrentUserSessionPro] }
    
    func validateProProof(_ proProof: String = "") -> Bool {
        return dependencies[feature: .treatAllIncomingMessagesAsProMessages]
    }
}
