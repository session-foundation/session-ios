// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionNetworkingKit
import SessionUtilitiesKit

public extension LibSession {
    struct Mutation {
        let sessionId: SessionId
        let needsPush: Bool
        let needsDump: Bool
        let skipAutomaticConfigSync: Bool
        let pendingEvents: [ObservedEvent]
        let dump: ConfigDump?
        let dependencies: Dependencies
        
        init(
            config: LibSession.Config?,
            sessionId: SessionId,
            skipAutomaticConfigSync: Bool,
            pendingEvents: [ObservedEvent],
            cache: LibSessionCacheType,
            using dependencies: Dependencies
        ) throws {
            self.sessionId = sessionId
            self.needsPush = (config?.needsPush == true)
            self.needsDump = cache.configNeedsDump(config)
            self.skipAutomaticConfigSync = skipAutomaticConfigSync
            self.pendingEvents = pendingEvents
            self.dump = (!self.needsDump ? nil :
                try config.map {
                    try cache.createDump(
                        config: $0,
                        for: $0.variant,
                        sessionId: sessionId,
                        timestampMs: dependencies.networkOffsetTimestampMs()
                    )
                }
            )
            self.dependencies = dependencies
        }
        
        public func upsert(_ db: ObservingDatabase) throws {
            /// Add and pending changes to the `db` so notifications go out for them after the transaction completes
            pendingEvents.forEach { db.addEvent($0) }
            
            /// If we don't need to dump or push then don't bother continuing
            guard needsDump || (needsPush && !skipAutomaticConfigSync) else { return }
            
            /// Only save the dump if needed
            if needsDump {
                try dump?.upsert(db)
            }
            
            db.afterCommit { [dump, dependencies] in
                /// Schedule a push if needed
                if needsPush && !skipAutomaticConfigSync {
                    dependencies[singleton: .storage].writeAsync { db in
                        ConfigurationSyncJob.enqueue(db, swarmPublicKey: sessionId.hexString, using: dependencies)
                    }
                }
                
                /// If we needed to dump then we should replicate it
                if needsDump {
                    Task.detached(priority: .medium) { [extensionHelper = dependencies[singleton: .extensionHelper]] in
                        extensionHelper.replicate(dump: dump)
                    }
                }
            }
        }
    }
}
