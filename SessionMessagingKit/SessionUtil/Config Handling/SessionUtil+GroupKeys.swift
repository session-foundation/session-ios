// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit

// MARK: - Size Restrictions

public extension SessionUtil {
    static var sizeAuthDataBytes: Int { 100 }
}

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
    static func rekey(
        _ db: Database,
        groupSessionId: SessionId,
        using dependencies: Dependencies
    ) throws {
        try SessionUtil.performAndPushChange(
            db,
            for: .groupKeys,
            sessionId: groupSessionId,
            using: dependencies
        ) { config in
            guard case .groupKeys(let conf, let infoConf, let membersConf) = config else {
                throw SessionUtilError.invalidConfigObject
            }
            
            // Performing a `rekey` returns the updated key data which we don't use directly, this updated
            // key will now be returned by `groups_keys_pending_config` which the `ConfigurationSyncJob` uses
            // when generating pending changes for group keys so we don't need to push it directly
            var pushResult: UnsafePointer<UInt8>? = nil
            var pushResultLen: Int = 0
            guard groups_keys_rekey(conf, infoConf, membersConf, &pushResult, &pushResultLen) else {
                throw SessionUtilError.failedToRekeyGroup
            }
        }
    }
    
    static func generateAuthData(
        _ db: Database,
        groupSessionId: SessionId,
        memberId: String,
        using dependencies: Dependencies
    ) throws -> Data {
        try dependencies[cache: .sessionUtil]
            .config(for: .groupKeys, sessionId: groupSessionId)
            .wrappedValue
            .map { config in
                guard case .groupKeys(let conf, _, _) = config else { throw SessionUtilError.invalidConfigObject }
                
                var authData: Data = Data(repeating: 0, count: SessionUtil.sizeAuthDataBytes)
                
                guard groups_keys_swarm_make_subaccount(
                    conf,
                    groupSessionId.hexString.toLibSession(),
                    &authData
                ) else { throw SessionUtilError.failedToMakeSubAccountInGroup }
                
                return authData
            } ?? { throw SessionUtilError.invalidConfigObject }()
    }
}
