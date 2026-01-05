// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit

// MARK: - ConvoInfoVolatile Handling

internal extension LibSession {
    static let columnsRelatedToConvoInfoVolatile: [ColumnExpression] = [
        // Note: We intentionally exclude 'Interaction.Columns.wasRead' from here as we want to
        // manually manage triggering config updates from marking as read
        SessionThread.Columns.markedAsUnread
    ]
}

// MARK: - Incoming Changes

internal extension LibSessionCacheType {
    func handleConvoInfoVolatileUpdate(
        _ db: ObservingDatabase,
        in config: LibSession.Config?
    ) throws {
        guard configNeedsDump(config) else { return }
        guard case .convoInfoVolatile(let conf) = config else {
            throw LibSessionError.invalidConfigObject(wanted: .convoInfoVolatile, got: config)
        }
        
        // Get the volatile thread info from the conf and local conversations
        let volatileThreadInfo: [LibSession.VolatileThreadInfo] = try LibSession.extractConvoVolatileInfo(from: conf)
        let localVolatileThreadInfo: [String: LibSession.VolatileThreadInfo] = LibSession.VolatileThreadInfo.fetchAll(db)
            .reduce(into: [:]) { result, next in result[next.threadId] = next }
        
        // Map the volatileThreadInfo, upserting any changes and returning a list of local changes
        // which should override any synced changes (eg. 'lastReadTimestampMs')
        let newerLocalChanges: [LibSession.VolatileThreadInfo] = try volatileThreadInfo
            .compactMap { threadInfo -> LibSession.VolatileThreadInfo? in
                // Note: A normal 'openGroupId' isn't lowercased but the volatile conversation
                // info will always be lowercase so we need to fetch the "proper" threadId (in
                // order to be able to update the corrent database entries)
                guard
                    let threadId: String = try? SessionThread
                        .select(.id)
                        .filter(SessionThread.Columns.id.lowercased == threadInfo.threadId)
                        .asRequest(of: String.self)
                        .fetchOne(db)
                else { return nil }
                
                
                // Get the existing local state for the thread
                let localThreadInfo: LibSession.VolatileThreadInfo? = localVolatileThreadInfo[threadId]
                
                // Update the thread 'markedAsUnread' state
                if
                    let markedAsUnread: Bool = threadInfo.changes.markedAsUnread,
                    markedAsUnread != (localThreadInfo?.changes.markedAsUnread ?? false)
                {
                    try SessionThread
                        .filter(id: threadId)
                        .updateAllAndConfig(
                            db,
                            SessionThread.Columns.markedAsUnread.set(to: markedAsUnread),
                            using: dependencies
                        )
                    db.addConversationEvent(
                        id: threadId,
                        variant: threadInfo.variant,
                        type: .updated(.markedAsUnread(markedAsUnread))
                    )
                }
                
                // If the device has a more recent read interaction then return the info so we can
                // update the cached config state accordingly
                guard
                    let lastReadTimestampMs: Int64 = threadInfo.changes.lastReadTimestampMs,
                    lastReadTimestampMs >= (localThreadInfo?.changes.lastReadTimestampMs ?? 0)
                else {
                    // We only want to return the 'lastReadTimestampMs' change, since the local state
                    // should win in that case, so ignore all others
                    return localThreadInfo?
                        .filterChanges { change in
                            switch change {
                                case .lastReadTimestampMs: return true
                                default: return false
                            }
                        }
                }
                
                // Mark all older interactions as read
                let interactionQuery = Interaction
                    .filter(Interaction.Columns.threadId == threadId)
                    .filter(Interaction.Columns.timestampMs <= lastReadTimestampMs)
                    .filter(Interaction.Columns.wasRead == false)
                let interactionInfoToMarkAsRead: [Interaction.ReadInfo] = try interactionQuery
                    .select(.id, .serverHash, .variant, .timestampMs, .wasRead)
                    .asRequest(of: Interaction.ReadInfo.self)
                    .fetchAll(db)
                try interactionQuery
                    .updateAllAndConfig(
                        db,
                        Interaction.Columns.wasRead.set(to: true),
                        using: dependencies
                    )
                try Interaction.scheduleReadJobs(
                    db,
                    threadId: threadId,
                    threadVariant: threadInfo.variant,
                    interactionInfo: interactionInfoToMarkAsRead,
                    lastReadTimestampMs: lastReadTimestampMs,
                    trySendReadReceipt: false,  // Interactions already read, no need to send
                    useLastReadTimestampForDisappearingMessages: true,
                    using: dependencies
                )
                return nil
            }
        
        // If there are no newer local last read timestamps then just return the mergeResult
        guard !newerLocalChanges.isEmpty else { return }
        
        try LibSession.upsert(
            convoInfoVolatileChanges: newerLocalChanges,
            in: config
        )
    }
}

internal extension LibSession {
    static func upsert(
        convoInfoVolatileChanges: [VolatileThreadInfo],
        in config: Config?
    ) throws {
        guard case .convoInfoVolatile(let conf) = config else {
            throw LibSessionError.invalidConfigObject(wanted: .convoInfoVolatile, got: config)
        }
        
        // Exclude any invalid thread info
        let validChanges: [VolatileThreadInfo] = convoInfoVolatileChanges
            .filter { info in
                switch info.variant {
                    case .contact:
                        // FIXME: libSession V1 doesn't sync volatileThreadInfo for blinded message requests
                        guard (try? SessionId(from: info.threadId))?.prefix == .standard else { return false }
                        
                        return true
                        
                    default: return true
                }
            }
        
        try validChanges.forEach { threadInfo in
            guard var cThreadId: [CChar] = threadInfo.threadId.cString(using: .utf8) else {
                Log.error(.libSession, "Unable to upsert contact volatile info to LibSession: \(LibSessionError.invalidCConversion)")
                throw LibSessionError.invalidCConversion
            }
            
            switch threadInfo.variant {
                case .contact:
                    var oneToOne: convo_info_volatile_1to1 = convo_info_volatile_1to1()
                    
                    guard convo_info_volatile_get_or_construct_1to1(conf, &oneToOne, &cThreadId) else {
                        /// It looks like there are some situations where this object might not get created correctly (and
                        /// will throw due to the implicit unwrapping) as a result we put it in a guard and throw instead
                        throw LibSessionError(
                            conf,
                            fallbackError: .getOrConstructFailedUnexpectedly,
                            logMessage: "Unable to upsert contact volatile info to LibSession"
                        )
                    }
                    
                    threadInfo.changes.forEach { change in
                        switch change {
                            case .lastReadTimestampMs(let lastReadMs):
                                oneToOne.last_read = max(oneToOne.last_read, lastReadMs)
                                
                            case .markedAsUnread(let unread):
                                oneToOne.unread = unread
                                
                            case .proProofMetadata(let metadata):
                                oneToOne.has_pro_gen_index_hash = (metadata != nil)
                                
                                guard let metadata: ProProofMetadata = metadata else { return }
                                
                                oneToOne.set(\.pro_gen_index_hash, to: Data(hex: metadata.genIndexHashHex))
                                oneToOne.pro_expiry_unix_ts_ms = metadata.expiryUnixTimestampMs
                        }
                    }
                    convo_info_volatile_set_1to1(conf, &oneToOne)
                    
                case .legacyGroup:
                    var legacyGroup: convo_info_volatile_legacy_group = convo_info_volatile_legacy_group()
                    
                    guard convo_info_volatile_get_or_construct_legacy_group(conf, &legacyGroup, &cThreadId) else {
                        /// It looks like there are some situations where this object might not get created correctly (and
                        /// will throw due to the implicit unwrapping) as a result we put it in a guard and throw instead
                        throw LibSessionError(
                            conf,
                            fallbackError: .getOrConstructFailedUnexpectedly,
                            logMessage: "Unable to upsert legacy group volatile info to LibSession"
                        )
                    }
                    
                    threadInfo.changes.forEach { change in
                        switch change {
                            case .lastReadTimestampMs(let lastReadMs):
                                legacyGroup.last_read = max(legacyGroup.last_read, lastReadMs)
                                
                            case .markedAsUnread(let unread):
                                legacyGroup.unread = unread
                                
                            case .proProofMetadata: break   /// Unsupported
                        }
                    }
                    convo_info_volatile_set_legacy_group(conf, &legacyGroup)
                    
                case .community:
                    guard
                        var cBaseUrl: [CChar] = threadInfo.openGroupUrlInfo?.server.cString(using: .utf8),
                        var cRoomToken: [CChar] = threadInfo.openGroupUrlInfo?.roomToken.cString(using: .utf8),
                        var cPubkey: [UInt8] = threadInfo.openGroupUrlInfo.map({ Array(Data(hex: $0.publicKey)) })
                    else {
                        Log.error(.libSession, "Unable to create community conversation when updating last read timestamp due to missing URL info")
                        return
                    }
                    
                    var community: convo_info_volatile_community = convo_info_volatile_community()
                    
                    guard convo_info_volatile_get_or_construct_community(conf, &community, &cBaseUrl, &cRoomToken, &cPubkey) else {
                        /// It looks like there are some situations where this object might not get created correctly (and
                        /// will throw due to the implicit unwrapping) as a result we put it in a guard and throw instead
                        throw LibSessionError(
                            conf,
                            fallbackError: .getOrConstructFailedUnexpectedly,
                            logMessage: "Unable to upsert community volatile info to LibSession"
                        )
                    }
                    
                    threadInfo.changes.forEach { change in
                        switch change {
                            case .lastReadTimestampMs(let lastReadMs):
                                community.last_read = max(community.last_read, lastReadMs)
                                
                            case .markedAsUnread(let unread):
                                community.unread = unread
                                
                            case .proProofMetadata: break   /// Unsupported
                        }
                    }
                    convo_info_volatile_set_community(conf, &community)
                    
                case .group:
                    var group: convo_info_volatile_group = convo_info_volatile_group()

                    guard convo_info_volatile_get_or_construct_group(conf, &group, &cThreadId) else {
                        /// It looks like there are some situations where this object might not get created correctly (and
                        /// will throw due to the implicit unwrapping) as a result we put it in a guard and throw instead
                        throw LibSessionError(
                            conf,
                            fallbackError: .getOrConstructFailedUnexpectedly,
                            logMessage: "Unable to upsert contact volatile info to LibSession"
                        )
                    }

                    threadInfo.changes.forEach { change in
                        switch change {
                            case .lastReadTimestampMs(let lastReadMs):
                                group.last_read = max(group.last_read, lastReadMs)

                            case .markedAsUnread(let unread):
                                group.unread = unread
                                
                            case .proProofMetadata: break   /// Unsupported
                        }
                    }
                    convo_info_volatile_set_group(conf, &group)
            }
        }
    }
    
    static func updateMarkedAsUnreadState(
        _ db: ObservingDatabase,
        threads: [SessionThread],
        using dependencies: Dependencies
    ) throws {
        // The current users thread data is stored in the `UserProfile` config so exclude it, we
        // also don't want to sync blinded message requests so exclude those as well
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        let targetThreads: [SessionThread] = threads
            .filter {
                $0.id != userSessionId.hexString &&
                (try? SessionId(from: $0.id))?.prefix != .blinded15 &&
                (try? SessionId(from: $0.id))?.prefix != .blinded25
            }
        
        // If we have no updated threads then no need to continue
        guard !targetThreads.isEmpty else { return }

        let changes: [VolatileThreadInfo] = try targetThreads.map { thread in
            VolatileThreadInfo(
                threadId: thread.id,
                variant: thread.variant,
                openGroupUrlInfo: (thread.variant != .community ? nil :
                    try OpenGroupUrlInfo.fetchOne(db, id: thread.id)
                ),
                changes: [.markedAsUnread(thread.markedAsUnread ?? false)]
            )
        }

        try dependencies.mutate(cache: .libSession) { cache in
            try cache.performAndPushChange(db, for: .convoInfoVolatile, sessionId: userSessionId) { config in
                try upsert(
                    convoInfoVolatileChanges: changes,
                    in: config
                )
            }
        }
    }
    
    static func remove(
        _ db: ObservingDatabase,
        volatileContactIds: [String],
        using dependencies: Dependencies
    ) throws {
        try dependencies.mutate(cache: .libSession) { cache in
            try cache.performAndPushChange(db, for: .convoInfoVolatile, sessionId: dependencies[cache: .general].sessionId) { config in
                guard case .convoInfoVolatile(let conf) = config else {
                    throw LibSessionError.invalidConfigObject(wanted: .convoInfoVolatile, got: config)
                }
                
                try volatileContactIds.forEach { contactId in
                    var cSessionId: [CChar] = try contactId.cString(using: .utf8) ?? { throw LibSessionError.invalidCConversion }()
                    
                    // Don't care if the data doesn't exist
                    convo_info_volatile_erase_1to1(conf, &cSessionId)
                }
            }
        }
    }
    
    static func remove(
        _ db: ObservingDatabase,
        volatileLegacyGroupIds: [String],
        using dependencies: Dependencies
    ) throws {
        try dependencies.mutate(cache: .libSession) { cache in
            try cache.performAndPushChange(db, for: .convoInfoVolatile, sessionId: dependencies[cache: .general].sessionId) { config in
                guard case .convoInfoVolatile(let conf) = config else {
                    throw LibSessionError.invalidConfigObject(wanted: .convoInfoVolatile, got: config)
                }
                
                try volatileLegacyGroupIds.forEach { legacyGroupId in
                    var cLegacyGroupId: [CChar] = try legacyGroupId.cString(using: .utf8) ?? {
                        throw LibSessionError.invalidCConversion
                    }()
                    
                    // Don't care if the data doesn't exist
                    convo_info_volatile_erase_legacy_group(conf, &cLegacyGroupId)
                }
            }
        }
    }
    
    static func remove(
        _ db: ObservingDatabase,
        volatileGroupSessionIds: [SessionId],
        using dependencies: Dependencies
    ) throws {
        try dependencies.mutate(cache: .libSession) { cache in
            try cache.performAndPushChange(db, for: .convoInfoVolatile, sessionId: dependencies[cache: .general].sessionId) { config in
                guard case .convoInfoVolatile(let conf) = config else {
                    throw LibSessionError.invalidConfigObject(wanted: .convoInfoVolatile, got: config)
                }
                
                try volatileGroupSessionIds.forEach { groupSessionId in
                    var cGroupId: [CChar] = try groupSessionId.hexString.cString(using: .utf8) ?? {
                        throw LibSessionError.invalidCConversion
                    }()
                    
                    // Don't care if the data doesn't exist
                    convo_info_volatile_erase_group(conf, &cGroupId)
                }
            }
        }
    }
    
    static func remove(
        _ db: ObservingDatabase,
        volatileCommunityInfo: [OpenGroupUrlInfo],
        using dependencies: Dependencies
    ) throws {
        try dependencies.mutate(cache: .libSession) { cache in
            try cache.performAndPushChange(db, for: .convoInfoVolatile, sessionId: dependencies[cache: .general].sessionId) { config in
                guard case .convoInfoVolatile(let conf) = config else {
                    throw LibSessionError.invalidConfigObject(wanted: .convoInfoVolatile, got: config)
                }
                
                try volatileCommunityInfo.forEach { urlInfo in
                    var cBaseUrl: [CChar] = try urlInfo.server.cString(using: .utf8) ?? { throw LibSessionError.invalidCConversion }()
                    var cRoom: [CChar] = try urlInfo.roomToken.cString(using: .utf8) ?? { throw LibSessionError.invalidCConversion }()
                    
                    // Don't care if the data doesn't exist
                    convo_info_volatile_erase_community(conf, &cBaseUrl, &cRoom)
                }
            }
        }
    }
}

// MARK: - External Outgoing Changes

public extension LibSession {
    static func syncThreadLastReadIfNeeded(
        _ db: ObservingDatabase,
        threadId: String,
        threadVariant: SessionThread.Variant,
        lastReadTimestampMs: Int64,
        using dependencies: Dependencies
    ) throws {
        try dependencies.mutate(cache: .libSession) { cache in
            try cache.performAndPushChange(db, for: .convoInfoVolatile, sessionId: dependencies[cache: .general].sessionId) { config in
                try upsert(
                    convoInfoVolatileChanges: [
                        VolatileThreadInfo(
                            threadId: threadId,
                            variant: threadVariant,
                            openGroupUrlInfo: (threadVariant != .community ? nil :
                                try OpenGroupUrlInfo.fetchOne(db, id: threadId)
                            ),
                            changes: [.lastReadTimestampMs(lastReadTimestampMs)]
                        )
                    ],
                    in: config
                )
            }
        }
    }
}

// MARK: State Access

public extension LibSession.Cache {
    func conversationLastRead(
        threadId: String,
        threadVariant: SessionThread.Variant,
        openGroupUrlInfo: LibSession.OpenGroupUrlInfo?
    ) -> Int64? {
        // If we don't have a config then just assume it's unread
        guard case .convoInfoVolatile(let conf) = config(for: .convoInfoVolatile, sessionId: userSessionId) else {
            return nil
        }
        
        switch threadVariant {
            case .contact:
                var oneToOne: convo_info_volatile_1to1 = convo_info_volatile_1to1()
                guard
                    var cThreadId: [CChar] = threadId.cString(using: .utf8),
                    convo_info_volatile_get_1to1(conf, &oneToOne, &cThreadId)
                else {
                    LibSessionError.clear(conf)
                    return nil
                }
                
                return oneToOne.last_read
                
            case .legacyGroup:
                var legacyGroup: convo_info_volatile_legacy_group = convo_info_volatile_legacy_group()
                
                guard
                    var cThreadId: [CChar] = threadId.cString(using: .utf8),
                    convo_info_volatile_get_legacy_group(conf, &legacyGroup, &cThreadId)
                else {
                    LibSessionError.clear(conf)
                    return nil
                }
                
                return legacyGroup.last_read
                
            case .community:
                var convoCommunity: convo_info_volatile_community = convo_info_volatile_community()
                
                guard
                    var cBaseUrl: [CChar] = openGroupUrlInfo?.server.cString(using: .utf8),
                    var cRoomToken: [CChar] = openGroupUrlInfo?.roomToken.cString(using: .utf8),
                    convo_info_volatile_get_community(conf, &convoCommunity, &cBaseUrl, &cRoomToken)
                else {
                    LibSessionError.clear(conf)
                    return nil
                }
                
                return convoCommunity.last_read
                
            case .group:
                var group: convo_info_volatile_group = convo_info_volatile_group()

                guard
                    var cThreadId: [CChar] = threadId.cString(using: .utf8),
                    convo_info_volatile_get_group(conf, &group, &cThreadId)
                else { return nil }

                return group.last_read
        }
    }
    
    func proProofMetadata(threadId: String) -> LibSession.ProProofMetadata? {
        /// If it's the current user then source from the `proConfig` instead
        guard threadId != userSessionId.hexString else {
            return proConfig.map { proConfig in
                return LibSession.ProProofMetadata(
                    genIndexHashHex: proConfig.proProof.genIndexHash.toHexString(),
                    expiryUnixTimestampMs: proConfig.proProof.expiryUnixTimestampMs
                )
            }
        }
        
        /// If we don't have a config then just assume the user is non-pro
        guard case .convoInfoVolatile(let conf) = config(for: .convoInfoVolatile, sessionId: userSessionId) else {
            return nil
        }
        
        switch try? SessionId.Prefix(from: threadId) {
            case .standard:
                var oneToOne: convo_info_volatile_1to1 = convo_info_volatile_1to1()
                guard
                    var cThreadId: [CChar] = threadId.cString(using: .utf8),
                    convo_info_volatile_get_1to1(conf, &oneToOne, &cThreadId)
                else {
                    LibSessionError.clear(conf)
                    return nil
                }
                guard oneToOne.has_pro_gen_index_hash else { return nil }
                
                return LibSession.ProProofMetadata(
                    genIndexHashHex: oneToOne.getHex(\.pro_gen_index_hash),
                    expiryUnixTimestampMs: oneToOne.pro_expiry_unix_ts_ms
                )
                
            case .blinded15, .blinded25:
                var blinded: convo_info_volatile_blinded_1to1 = convo_info_volatile_blinded_1to1()
                guard
                    var cThreadId: [CChar] = threadId.cString(using: .utf8),
                    convo_info_volatile_get_blinded_1to1(conf, &blinded, &cThreadId)
                else {
                    LibSessionError.clear(conf)
                    return nil
                }
                guard blinded.has_pro_gen_index_hash else { return nil }
                
                return LibSession.ProProofMetadata(
                    genIndexHashHex: blinded.getHex(\.pro_gen_index_hash),
                    expiryUnixTimestampMs: blinded.pro_expiry_unix_ts_ms
                )
                
            default: return nil    /// Other conversation types don't have `ProProofMetadata`
        }
    }
}

// MARK: State Access

public extension LibSessionCacheType {
    func timestampAlreadyRead(
        threadId: String,
        threadVariant: SessionThread.Variant,
        timestampMs: UInt64,
        openGroupUrlInfo: LibSession.OpenGroupUrlInfo?
    ) -> Bool {
        let lastReadTimestampMs: Int64? = conversationLastRead(
            threadId: threadId,
            threadVariant: threadVariant,
            openGroupUrlInfo: openGroupUrlInfo
        )
        
        return ((lastReadTimestampMs ?? 0) >= Int64(timestampMs))
    }
}

// MARK: - VolatileThreadInfo

public extension LibSession {
    struct ProProofMetadata {
        let genIndexHashHex: String
        let expiryUnixTimestampMs: UInt64
    }
    
    struct VolatileThreadInfo {
        enum Change {
            case markedAsUnread(Bool)
            case lastReadTimestampMs(Int64)
            case proProofMetadata(ProProofMetadata?)
        }
        
        let threadId: String
        let variant: SessionThread.Variant
        fileprivate let openGroupUrlInfo: OpenGroupUrlInfo?
        let changes: [Change]
        
        internal init(
            threadId: String,
            variant: SessionThread.Variant,
            openGroupUrlInfo: OpenGroupUrlInfo? = nil,
            changes: [Change]
        ) {
            self.threadId = threadId
            self.variant = variant
            self.openGroupUrlInfo = openGroupUrlInfo
            self.changes = changes
        }
        
        // MARK: - Convenience
        
        func filterChanges(isIncluded: (Change) -> Bool) -> VolatileThreadInfo {
            return VolatileThreadInfo(
                threadId: threadId,
                variant: variant,
                openGroupUrlInfo: openGroupUrlInfo,
                changes: changes.filter(isIncluded)
            )
        }
        
        static func fetchAll(_ db: ObservingDatabase, ids: [String]? = nil) -> [VolatileThreadInfo] {
            struct FetchedInfo: FetchableRecord, Codable, Hashable {
                let id: String
                let variant: SessionThread.Variant
                let markedAsUnread: Bool?
                let timestampMs: Int64?
                let server: String?
                let roomToken: String?
                let publicKey: String?
            }
            
            let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
            let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
            let openGroup: TypedTableAlias<OpenGroup> = TypedTableAlias()
            let timestampMsLiteral: SQL = SQL(stringLiteral: Interaction.Columns.timestampMs.name)
            let request: SQLRequest<FetchedInfo> = """
                SELECT
                    \(thread[.id]),
                    \(thread[.variant]),
                    \(thread[.markedAsUnread]),
                    \(interaction[.timestampMs]),
                    \(openGroup[.server]),
                    \(openGroup[.roomToken]),
                    \(openGroup[.publicKey])
                
                FROM \(SessionThread.self)
                LEFT JOIN (
                    SELECT
                        \(interaction[.threadId]),
                        MAX(\(interaction[.timestampMs])) AS \(timestampMsLiteral)
                    FROM \(Interaction.self)
                    WHERE (
                        \(interaction[.wasRead]) = true AND
                        -- Note: Due to the complexity of how call messages are handled and the short
                        -- duration they exist in the swarm, we have decided to exclude trying to
                        -- include them when syncing the read status of conversations (they are also
                        -- implemented differently between platforms so including them could be a
                        -- significant amount of work)
                        \(SQL("\(interaction[.variant]) IN \(Interaction.Variant.variantsToIncrementUnreadCount.filter { $0 != .infoCall })"))
                    )
                    GROUP BY \(interaction[.threadId])
                ) AS \(Interaction.self) ON \(interaction[.threadId]) = \(thread[.id])
                LEFT JOIN \(OpenGroup.self) ON \(openGroup[.threadId]) = \(thread[.id])
                \(ids == nil ? SQL("") :
                "WHERE \(SQL("\(thread[.id]) IN \(ids ?? [])"))"
                )
                GROUP BY \(thread[.id])
            """
            
            return ((try? request.fetchAll(db)) ?? [])
                .map { threadInfo in
                    VolatileThreadInfo(
                        threadId: threadInfo.id,
                        variant: threadInfo.variant,
                        openGroupUrlInfo: {
                            guard
                                let server: String = threadInfo.server,
                                let roomToken: String = threadInfo.roomToken,
                                let publicKey: String = threadInfo.publicKey
                            else { return nil }
                            
                            return OpenGroupUrlInfo(
                                threadId: threadInfo.id,
                                server: server,
                                roomToken: roomToken,
                                publicKey: publicKey
                            )
                        }(),
                        changes: [
                            .markedAsUnread(threadInfo.markedAsUnread ?? false),
                            .lastReadTimestampMs(threadInfo.timestampMs ?? 0)
                        ]
                    )
                }
        }
    }
    
    internal static func extractConvoVolatileInfo(
        from conf: UnsafeMutablePointer<config_object>?
    ) throws -> [VolatileThreadInfo] {
        var infiniteLoopGuard: Int = 0
        var result: [VolatileThreadInfo] = []
        var oneToOne: convo_info_volatile_1to1 = convo_info_volatile_1to1()
        var community: convo_info_volatile_community = convo_info_volatile_community()
        var legacyGroup: convo_info_volatile_legacy_group = convo_info_volatile_legacy_group()
        var group: convo_info_volatile_group = convo_info_volatile_group()
        var blinded: convo_info_volatile_blinded_1to1 = convo_info_volatile_blinded_1to1()
        let convoIterator: OpaquePointer = convo_info_volatile_iterator_new(conf)

        while !convo_info_volatile_iterator_done(convoIterator) {
            try LibSession.checkLoopLimitReached(&infiniteLoopGuard, for: .convoInfoVolatile)
            
            if convo_info_volatile_it_is_1to1(convoIterator, &oneToOne) {
                result.append(
                    VolatileThreadInfo(
                        threadId: oneToOne.get(\.session_id),
                        variant: .contact,
                        changes: [
                            .markedAsUnread(oneToOne.unread),
                            .lastReadTimestampMs(oneToOne.last_read),
                            .proProofMetadata({
                                guard oneToOne.has_pro_gen_index_hash else { return nil }
                                
                                return ProProofMetadata(
                                    genIndexHashHex: oneToOne.getHex(\.pro_gen_index_hash),
                                    expiryUnixTimestampMs: oneToOne.pro_expiry_unix_ts_ms
                                )
                            }())
                        ]
                    )
                )
            }
            else if convo_info_volatile_it_is_community(convoIterator, &community) {
                let server: String = community.get(\.base_url)
                let roomToken: String = community.get(\.room)
                let publicKey: String = community.getHex(\.pubkey)
                
                result.append(
                    VolatileThreadInfo(
                        threadId: OpenGroup.idFor(roomToken: roomToken, server: server),
                        variant: .community,
                        openGroupUrlInfo: OpenGroupUrlInfo(
                            threadId: OpenGroup.idFor(roomToken: roomToken, server: server),
                            server: server,
                            roomToken: roomToken,
                            publicKey: publicKey
                        ),
                        changes: [
                            .markedAsUnread(community.unread),
                            .lastReadTimestampMs(community.last_read)
                        ]
                    )
                )
            }
            else if convo_info_volatile_it_is_legacy_group(convoIterator, &legacyGroup) {
                result.append(
                    VolatileThreadInfo(
                        threadId: legacyGroup.get(\.group_id),
                        variant: .legacyGroup,
                        changes: [
                            .markedAsUnread(legacyGroup.unread),
                            .lastReadTimestampMs(legacyGroup.last_read)
                        ]
                    )
                )
            }
            else if convo_info_volatile_it_is_group(convoIterator, &group) {
                result.append(
                    VolatileThreadInfo(
                        threadId: group.get(\.group_id),
                        variant: .group,
                        changes: [
                            .markedAsUnread(group.unread),
                            .lastReadTimestampMs(group.last_read)
                        ]
                    )
                )
            }
            else if convo_info_volatile_it_is_blinded_1to1(convoIterator, &blinded) {
                result.append(
                    VolatileThreadInfo(
                        threadId: blinded.get(\.blinded_session_id),
                        variant: .contact,
                        changes: [
                            .markedAsUnread(blinded.unread),
                            .lastReadTimestampMs(blinded.last_read),
                            .proProofMetadata({
                                guard blinded.has_pro_gen_index_hash else { return nil }
                                
                                return ProProofMetadata(
                                    genIndexHashHex: blinded.getHex(\.pro_gen_index_hash),
                                    expiryUnixTimestampMs: blinded.pro_expiry_unix_ts_ms
                                )
                            }())
                        ]
                    )
                )
            }
            else {
                Log.error(.libSession, "Ignoring unknown conversation type when iterating through volatile conversation info update")
            }
            
            convo_info_volatile_iterator_advance(convoIterator)
        }
        convo_info_volatile_iterator_free(convoIterator) // Need to free the iterator
        
        return result
    }
}

fileprivate extension [LibSession.VolatileThreadInfo.Change] {
    var markedAsUnread: Bool? {
        for change in self {
            switch change {
                case .markedAsUnread(let value): return value
                default: continue
            }
        }
        
        return nil
    }
    
    var lastReadTimestampMs: Int64? {
        for change in self {
            switch change {
                case .lastReadTimestampMs(let value): return value
                default: continue
            }
        }
        
        return nil
    }
}

// MARK: - C Conformance

extension convo_info_volatile_1to1: CAccessible & CMutable {}
extension convo_info_volatile_community: CAccessible & CMutable {}
extension convo_info_volatile_legacy_group: CAccessible & CMutable {}
extension convo_info_volatile_group: CAccessible & CMutable {}
extension convo_info_volatile_blinded_1to1: CAccessible & CMutable {}
