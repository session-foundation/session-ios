// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit

// MARK: - Size Restrictions

public extension SessionUtil {
    static var sizeAuthDataBytes: Int { 100 }
    static var sizeSubaccountBytes: Int { 36 }
    static var sizeSubaccountSigBytes: Int { 64 }
    static var sizeSubaccountSignatureBytes: Int { 64 }
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
    
    static func keySupplement(
        _ db: Database,
        groupSessionId: SessionId,
        memberIds: Set<String>,
        using dependencies: Dependencies
    ) throws {
        try SessionUtil.performAndPushChange(
            db,
            for: .groupKeys,
            sessionId: groupSessionId,
            using: dependencies
        ) { config in
            guard case .groupKeys(let conf, _, _) = config else { throw SessionUtilError.invalidConfigObject }
            
            var cMemberIds: [UnsafePointer<CChar>?] = memberIds
                .map { id in id.cArray.nullTerminated() }
                .unsafeCopy()
            
            defer { cMemberIds.forEach { $0?.deallocate() } }
            
            // Performing a `key_supplement` returns the updated key data which we don't use directly, this updated
            // key will now be returned by `groups_keys_pending_config` which the `ConfigurationSyncJob` uses
            // when generating pending changes for group keys so we don't need to push it directly
            var pushResult: UnsafeMutablePointer<UInt8>? = nil
            var pushResultLen: Int = 0
            guard groups_keys_key_supplement(conf, &cMemberIds, cMemberIds.count, &pushResult, &pushResultLen) else {
                throw SessionUtilError.failedToKeySupplementGroup
            }
            
            // Must deallocate on success
            pushResult?.deallocate()
        }
    }
    
    static func generateAuthData(
        groupSessionId: SessionId,
        memberId: String,
        using dependencies: Dependencies
    ) throws -> Authentication.Info {
        try dependencies[singleton: .crypto].generate(
            .memberAuthData(
                config: dependencies[cache: .sessionUtil]
                    .config(for: .groupKeys, sessionId: groupSessionId)
                    .wrappedValue,
                groupSessionId: groupSessionId,
                memberId: memberId
            )
        )
    }
    
    static func generateSubaccountSignature(
        groupSessionId: SessionId,
        verificationBytes: [UInt8],
        memberAuthData: Data,
        using dependencies: Dependencies
    ) throws -> Authentication.Signature {
        try dependencies[singleton: .crypto].generate(
            .subaccountSignature(
                config: dependencies[cache: .sessionUtil]
                    .config(for: .groupKeys, sessionId: groupSessionId)
                    .wrappedValue,
                verificationBytes: verificationBytes,
                memberAuthData: memberAuthData
            )
        )
    }
}
