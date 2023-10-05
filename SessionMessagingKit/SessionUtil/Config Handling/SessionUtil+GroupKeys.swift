// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit

// MARK: - Group Info Handling

internal extension SessionUtil {
    static let columnsRelatedToGroupKeys: [ColumnExpression] = []
    
    // MARK: - Incoming Changes
    
    static func handleGroupKeysUpdate(
        _ db: Database,
        in config: Config?,
        groupSessionId: SessionId,
        using dependencies: Dependencies
    ) throws {
        guard config.needsDump else { return }
        guard case .groupKeys(let conf, _, _) = config else { throw SessionUtilError.invalidConfigObject }
    }
}

// MARK: - Outgoing Changes

internal extension SessionUtil {
}
