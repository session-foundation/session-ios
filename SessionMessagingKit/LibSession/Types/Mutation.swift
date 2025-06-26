// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

public extension LibSession {
    struct Mutation {
        let sessionId: SessionId
        let needsPush: Bool
        let needsDump: Bool
        let skipAutomaticConfigSync: Bool
        let pendingChanges: [(key: ObservableKey, value: Any?)]
        let dump: ConfigDump?
        let dependencies: Dependencies
        
        init(
            config: LibSession.Config?,
            sessionId: SessionId,
            skipAutomaticConfigSync: Bool,
            pendingChanges: [(key: ObservableKey, value: Any?)],
            cache: LibSessionCacheType,
            using dependencies: Dependencies
        ) throws {
            self.sessionId = sessionId
            self.needsPush = (config?.needsPush == true)
            self.needsDump = cache.configNeedsDump(config)
            self.skipAutomaticConfigSync = skipAutomaticConfigSync
            self.pendingChanges = pendingChanges
            self.dump = (!self.needsDump ? nil :
                try config.map {
                    try cache.createDump(
                        config: $0,
                        for: $0.variant,
                        sessionId: sessionId,
                        timestampMs: dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
                    )
                }
            )
            self.dependencies = dependencies
        }
        
        public func upsert(_ db: ObservingDatabase) throws {
            /// Add and pending changes to the `db` so notifications go out for them after the transaction completes
            pendingChanges.forEach { key, value in
                db.addChange(value, forKey: key)
            }
            
            /// If we don't need to dump or push then don't bother continuing
            guard needsDump || (needsPush && !skipAutomaticConfigSync) else { return }
            
            /// Only save the dump if needed
            if needsDump {
                try dump?.upsert(db)
            }
            
            db.afterNextTransactionNested(using: dependencies) { [dump, dependencies] db in
                /// Schedule a push if needed
                if needsPush && !skipAutomaticConfigSync {
                    ConfigurationSyncJob.enqueue(db, swarmPublicKey: sessionId.hexString, using: dependencies)
                }
                
                /// If we needed to dump then we should replicate it
                if needsDump {
                    Task.detached(priority: .medium) {
                        dependencies[singleton: .extensionHelper].replicate(dump: dump)
                    }
                }
            }
        }
    }
}
