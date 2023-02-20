// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit

internal extension SessionUtil {
    // MARK: - Incoming Changes
    
    static func handleConvoInfoVolatileUpdate(
        _ db: Database,
        in atomicConf: Atomic<UnsafeMutablePointer<config_object>?>,
        mergeResult: ConfResult
    ) throws -> ConfResult {
        guard mergeResult.needsDump else { return mergeResult }
        guard atomicConf.wrappedValue != nil else { throw SessionUtilError.nilConfigObject }
        
        // Since we are doing direct memory manipulation we are using an `Atomic` type which has
        // blocking access in it's `mutate` closure
        let volatileThreadInfo: [VolatileThreadInfo] = atomicConf.mutate { conf -> [VolatileThreadInfo] in
            var volatileThreadInfo: [VolatileThreadInfo] = []
            var oneToOne: convo_info_volatile_1to1 = convo_info_volatile_1to1()
            var community: convo_info_volatile_community = convo_info_volatile_community()
            var legacyGroup: convo_info_volatile_legacy_group = convo_info_volatile_legacy_group()
            let convoIterator: OpaquePointer = convo_info_volatile_iterator_new(conf)

            while !convo_info_volatile_iterator_done(convoIterator) {
                if convo_info_volatile_it_is_1to1(convoIterator, &oneToOne) {
                    let sessionId: String = String(cString: withUnsafeBytes(of: oneToOne.session_id) { [UInt8]($0) }
                        .map { CChar($0) }
                        .nullTerminated()
                    )
                    
                    volatileThreadInfo.append(
                        VolatileThreadInfo(
                            threadId: sessionId,
                            variant: .contact,
                            changes: [
                                .markedAsUnread(oneToOne.unread),
                                .lastReadTimestampMs(oneToOne.last_read)
                            ]
                        )
                    )
                }
                else if convo_info_volatile_it_is_community(convoIterator, &community) {
                    let server: String = String(cString: withUnsafeBytes(of: community.base_url) { [UInt8]($0) }
                        .map { CChar($0) }
                        .nullTerminated()
                    )
                    let roomToken: String = String(cString: withUnsafeBytes(of: community.room) { [UInt8]($0) }
                        .map { CChar($0) }
                        .nullTerminated()
                    )
                    let publicKey: String = withUnsafePointer(to: community.pubkey, { pubkeyBytes in
                        Data(bytes: pubkeyBytes, count: 32).toHexString()
                    })
                    
                    volatileThreadInfo.append(
                        VolatileThreadInfo(
                            threadId: OpenGroup.idFor(roomToken: roomToken, server: server),
                            variant: .community,
                            openGroupUrlInfo: VolatileThreadInfo.OpenGroupUrlInfo(
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
                    let groupId: String = String(cString: withUnsafeBytes(of: legacyGroup.group_id) { [UInt8]($0) }
                        .map { CChar($0) }
                        .nullTerminated()
                    )
                    
                    volatileThreadInfo.append(
                        VolatileThreadInfo(
                            threadId: groupId,
                            variant: .legacyGroup,
                            changes: [
                                .markedAsUnread(legacyGroup.unread),
                                .lastReadTimestampMs(legacyGroup.last_read)
                            ]
                        )
                    )
                }
                else {
                    SNLog("Ignoring unknown conversation type when iterating through volatile conversation info update")
                }
                
                convo_info_volatile_iterator_advance(convoIterator)
            }
            convo_info_volatile_iterator_free(convoIterator) // Need to free the iterator
            
            return volatileThreadInfo
        }

        // If we don't have any conversations then no need to continue
        guard !volatileThreadInfo.isEmpty else { return mergeResult }
        
        // Get the local volatile thread info from all conversations
        let localVolatileThreadInfo: [String: VolatileThreadInfo] = VolatileThreadInfo.fetchAll(db)
            .reduce(into: [:]) { result, next in result[next.threadId] = next }
        
        // Map the volatileThreadInfo, upserting any changes and returning a list of local changes
        // which should override any synced changes (eg. 'lastReadTimestampMs')
        let newerLocalChanges: [VolatileThreadInfo] = try volatileThreadInfo
            .compactMap { threadInfo -> VolatileThreadInfo? in
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
                let localThreadInfo: VolatileThreadInfo? = localVolatileThreadInfo[threadId]
                
                // Update the thread 'markedAsUnread' state
                if
                    let markedAsUnread: Bool = threadInfo.changes.markedAsUnread,
                    markedAsUnread != (localThreadInfo?.changes.markedAsUnread ?? false)
                {
                    try SessionThread
                        .filter(id: threadId)
                        .updateAll( // Handling a config update so don't use `updateAllAndConfig`
                            db,
                            SessionThread.Columns.markedAsUnread.set(to: markedAsUnread)
                        )
                }
                
                // If the device has a more recent read interaction then return the info so we can
                // update the cached config state accordingly
                guard
                    let lastReadTimestampMs: Int64 = threadInfo.changes.lastReadTimestampMs,
                    lastReadTimestampMs > (localThreadInfo?.changes.lastReadTimestampMs ?? 0)
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
                try Interaction
                    .filter(
                        Interaction.Columns.threadId == threadId &&
                        Interaction.Columns.timestampMs <= lastReadTimestampMs
                    )
                    .updateAll( // Handling a config update so don't use `updateAllAndConfig`
                        db,
                        Interaction.Columns.wasRead.set(to: true)
                    )
                return nil
            }
        
        // If there are no newer local last read timestamps then just return the mergeResult
        guard !newerLocalChanges.isEmpty else { return mergeResult }
        
        return try upsert(
            convoInfoVolatileChanges: newerLocalChanges,
            in: atomicConf
        )
    }
    
    static func upsert(
        convoInfoVolatileChanges: [VolatileThreadInfo],
        in atomicConf: Atomic<UnsafeMutablePointer<config_object>?>
    ) throws -> ConfResult {
        guard atomicConf.wrappedValue != nil else { throw SessionUtilError.nilConfigObject }
        
        // Since we are doing direct memory manipulation we are using an `Atomic` type which has
        // blocking access in it's `mutate` closure
        return atomicConf.mutate { conf in
            convoInfoVolatileChanges.forEach { threadInfo in
                var cThreadId: [CChar] = threadInfo.threadId.cArray
                
                switch threadInfo.variant {
                    case .contact:
                        var oneToOne: convo_info_volatile_1to1 = convo_info_volatile_1to1()
                        
                        guard convo_info_volatile_get_or_construct_1to1(conf, &oneToOne, &cThreadId) else {
                            SNLog("Unable to create contact conversation when updating last read timestamp")
                            return
                        }
                        
                        threadInfo.changes.forEach { change in
                            switch change {
                                case .lastReadTimestampMs(let lastReadMs):
                                    oneToOne.last_read = lastReadMs
                                    
                                case .markedAsUnread(let unread):
                                    oneToOne.unread = unread
                            }
                        }
                        convo_info_volatile_set_1to1(conf, &oneToOne)
                        
                    case .legacyGroup:
                        var legacyGroup: convo_info_volatile_legacy_group = convo_info_volatile_legacy_group()
                        
                        guard convo_info_volatile_get_or_construct_legacy_group(conf, &legacyGroup, &cThreadId) else {
                            SNLog("Unable to create legacy group conversation when updating last read timestamp")
                            return
                        }
                        
                        threadInfo.changes.forEach { change in
                            switch change {
                                case .lastReadTimestampMs(let lastReadMs):
                                    legacyGroup.last_read = lastReadMs
                                    
                                case .markedAsUnread(let unread):
                                    legacyGroup.unread = unread
                            }
                        }
                        convo_info_volatile_set_legacy_group(conf, &legacyGroup)
                        
                    case .community:
                        guard
                            var cBaseUrl: [CChar] = threadInfo.openGroupUrlInfo?.server.cArray,
                            var cRoomToken: [CChar] = threadInfo.openGroupUrlInfo?.roomToken.cArray,
                            var cPubkey: [UInt8] = threadInfo.openGroupUrlInfo?.publicKey.bytes
                        else {
                            SNLog("Unable to create community conversation when updating last read timestamp due to missing URL info")
                            return
                        }
                        
                        var community: convo_info_volatile_community = convo_info_volatile_community()
                        
                        guard convo_info_volatile_get_or_construct_community(conf, &community, &cBaseUrl, &cRoomToken, &cPubkey) else {
                            SNLog("Unable to create legacy group conversation when updating last read timestamp")
                            return
                        }
                        
                        threadInfo.changes.forEach { change in
                            switch change {
                                case .lastReadTimestampMs(let lastReadMs):
                                    community.last_read = lastReadMs
                                    
                                case .markedAsUnread(let unread):
                                    community.unread = unread
                            }
                        }
                        convo_info_volatile_set_community(conf, &community)
                        
                    case .group: return   // TODO: Need to add when the type is added to the lib
                }
            }
            
            return ConfResult(
                needsPush: config_needs_push(conf),
                needsDump: config_needs_dump(conf)
            )
        }
    }
}

// MARK: - Convenience

internal extension SessionUtil {
    static func updatingThreads<T>(_ db: Database, _ updated: [T]) throws -> [T] {
        guard let updatedThreads: [SessionThread] = updated as? [SessionThread] else {
            throw StorageError.generic
        }
        
        // If we have no updated threads then no need to continue
        guard !updatedThreads.isEmpty else { return updated }
        
        let userPublicKey: String = getUserHexEncodedPublicKey(db)
        let changes: [VolatileThreadInfo] = try updatedThreads.map { thread in
            VolatileThreadInfo(
                threadId: thread.id,
                variant: thread.variant,
                openGroupUrlInfo: (thread.variant != .community ? nil :
                    try VolatileThreadInfo.OpenGroupUrlInfo.fetchOne(db, id: thread.id)
                ),
                changes: [.markedAsUnread(thread.markedAsUnread ?? false)]
            )
        }
        
        db.afterNextTransactionNested { db in
            do {
                let atomicConf: Atomic<UnsafeMutablePointer<config_object>?> = SessionUtil.config(
                    for: .convoInfoVolatile,
                    publicKey: userPublicKey
                )
                let result: ConfResult = try upsert(
                    convoInfoVolatileChanges: changes,
                    in: atomicConf
                )
                
                // If we don't need to dump the data the we can finish early
                guard result.needsDump else { return }
                
                try SessionUtil.saveState(
                    db,
                    keepingExistingMessageHashes: true,
                    configDump: try atomicConf.mutate { conf in
                        try SessionUtil.createDump(
                            conf: conf,
                            for: .convoInfoVolatile,
                            publicKey: userPublicKey,
                            messageHashes: nil
                        )
                    }
                )
            }
            catch {
                SNLog("[libSession-util] Failed to dump updated data")
            }
        }
        
        return updated
    }
    
    static func syncThreadLastReadIfNeeded(
        _ db: Database,
        threadId: String,
        threadVariant: SessionThread.Variant,
        lastReadTimestampMs: Int64
    ) throws {
        let userPublicKey: String = getUserHexEncodedPublicKey(db)
        let atomicConf: Atomic<UnsafeMutablePointer<config_object>?> = SessionUtil.config(
            for: .convoInfoVolatile,
            publicKey: userPublicKey
        )
        let change: VolatileThreadInfo = VolatileThreadInfo(
            threadId: threadId,
            variant: threadVariant,
            openGroupUrlInfo: (threadVariant != .community ? nil :
                try VolatileThreadInfo.OpenGroupUrlInfo.fetchOne(db, id: threadId)
            ),
            changes: [.lastReadTimestampMs(lastReadTimestampMs)]
        )
        
        // Update the conf
        let result: ConfResult = try upsert(
            convoInfoVolatileChanges: [change],
            in: atomicConf
        )
        
        // If we need to dump then do so here
        if result.needsDump {
            try SessionUtil.saveState(
                db,
                keepingExistingMessageHashes: true,
                configDump: try atomicConf.mutate { conf in
                    try SessionUtil.createDump(
                        conf: conf,
                        for: .contacts,
                        publicKey: userPublicKey,
                        messageHashes: nil
                    )
                }
            )
        }
        
        // If we need to push then enqueue a 'ConfigurationSyncJob'
        if result.needsPush {
            ConfigurationSyncJob.enqueue(db)
        }
    }
    
    static func timestampAlreadyRead(
        threadId: String,
        threadVariant: SessionThread.Variant,
        timestampMs: Int64,
        userPublicKey: String,
        openGroup: OpenGroup?
    ) -> Bool {
        let atomicConf: Atomic<UnsafeMutablePointer<config_object>?> = SessionUtil.config(
            for: .convoInfoVolatile,
            publicKey: userPublicKey
        )
        
        // If we don't have a config then just assume it's unread
        guard atomicConf.wrappedValue != nil else { return false }
        
        // Since we are doing direct memory manipulation we are using an `Atomic` type which has
        // blocking access in it's `mutate` closure
        return atomicConf.mutate { conf in
            switch threadVariant {
                case .contact:
                    var cThreadId: [CChar] = threadId.cArray
                    var oneToOne: convo_info_volatile_1to1 = convo_info_volatile_1to1()
                    guard convo_info_volatile_get_1to1(conf, &oneToOne, &cThreadId) else { return false }
                    
                    return (oneToOne.last_read > timestampMs)
                    
                case .legacyGroup:
                    var cThreadId: [CChar] = threadId.cArray
                    var legacyGroup: convo_info_volatile_legacy_group = convo_info_volatile_legacy_group()
                    
                    guard convo_info_volatile_get_legacy_group(conf, &legacyGroup, &cThreadId) else {
                        return false
                    }
                    
                    return (legacyGroup.last_read > timestampMs)
                    
                case .community:
                    guard let openGroup: OpenGroup = openGroup else { return false }
                    
                    var cBaseUrl: [CChar] = openGroup.server.cArray
                    var cRoomToken: [CChar] = openGroup.roomToken.cArray
                    var convoCommunity: convo_info_volatile_community = convo_info_volatile_community()
                    
                    guard convo_info_volatile_get_community(conf, &convoCommunity, &cBaseUrl, &cRoomToken) else {
                        return false
                    }
                    
                    return (convoCommunity.last_read > timestampMs)
                    
                case .group: return false // TODO: Need to add when the type is added to the lib
            }
        }
    }
}

// MARK: - VolatileThreadInfo

public extension SessionUtil {
    struct VolatileThreadInfo {
        enum Change {
            case markedAsUnread(Bool)
            case lastReadTimestampMs(Int64)
        }
        
        fileprivate struct OpenGroupUrlInfo: FetchableRecord, Codable, Hashable {
            let threadId: String
            let server: String
            let roomToken: String
            let publicKey: String
            
            static func fetchOne(_ db: Database, id: String) throws -> OpenGroupUrlInfo? {
                return try OpenGroup
                    .filter(id: id)
                    .select(.threadId, .server, .roomToken, .publicKey)
                    .asRequest(of: OpenGroupUrlInfo.self)
                    .fetchOne(db)
            }
        }
        
        let threadId: String
        let variant: SessionThread.Variant
        fileprivate let openGroupUrlInfo: OpenGroupUrlInfo?
        let changes: [Change]
        
        fileprivate init(
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
        
        static func fetchAll(_ db: Database? = nil, ids: [String]? = nil) -> [VolatileThreadInfo] {
            guard let db: Database = db else {
                return Storage.shared
                    .read { db in fetchAll(db, ids: ids) }
                    .defaulting(to: [])
            }
            
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
                            
                            return VolatileThreadInfo.OpenGroupUrlInfo(
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
}

fileprivate extension [SessionUtil.VolatileThreadInfo.Change] {
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
