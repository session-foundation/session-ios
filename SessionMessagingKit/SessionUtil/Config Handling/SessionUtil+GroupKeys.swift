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
        in conf: UnsafeMutablePointer<config_object>?,
        mergeNeedsDump: Bool,
        latestConfigSentTimestampMs: Int64
    ) throws {
        guard mergeNeedsDump else { return }
        guard conf != nil else { throw SessionUtilError.nilConfigObject }
    }
}

// MARK: - Outgoing Changes

internal extension SessionUtil {
}
