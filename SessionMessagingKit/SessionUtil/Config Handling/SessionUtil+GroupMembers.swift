// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit

// MARK: - Group Info Handling

internal extension SessionUtil {
    static let columnsRelatedToGroupMembers: [ColumnExpression] = []
    
    // MARK: - Incoming Changes
    
    static func handleGroupMembersUpdate(
        _ db: Database,
        in config: Config?,
        latestConfigSentTimestampMs: Int64,
        using dependencies: Dependencies
    ) throws {
        guard config.needsDump else { return }
        guard case .object(let conf) = config else { throw SessionUtilError.invalidConfigObject }
    }
}

// MARK: - Outgoing Changes

internal extension SessionUtil {
}
