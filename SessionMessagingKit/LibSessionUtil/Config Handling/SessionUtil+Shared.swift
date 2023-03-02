// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit

// MARK: - Convenience

internal extension SessionUtil {
    static let columnsRelatedToThreads: [ColumnExpression] = [
        SessionThread.Columns.pinnedPriority,
        SessionThread.Columns.shouldBeVisible
    ]
    
    static func assignmentsRequireConfigUpdate(_ assignments: [ConfigColumnAssignment]) -> Bool {
        let targetColumns: Set<ColumnKey> = Set(assignments.map { ColumnKey($0.column) })
        let allColumnsThatTriggerConfigUpdate: Set<ColumnKey> = []
            .appending(contentsOf: columnsRelatedToUserProfile)
            .appending(contentsOf: columnsRelatedToContacts)
            .appending(contentsOf: columnsRelatedToConvoInfoVolatile)
            .appending(contentsOf: columnsRelatedToUserGroups)
            .map { ColumnKey($0) }
            .asSet()
        
        return !allColumnsThatTriggerConfigUpdate.isDisjoint(with: targetColumns)
    }
    
    static func performAndPushChange(
        _ db: Database,
        for variant: ConfigDump.Variant,
        publicKey: String,
        change: (UnsafeMutablePointer<config_object>?) throws -> ()
    ) throws {
        // Since we are doing direct memory manipulation we are using an `Atomic`
        // type which has blocking access in it's `mutate` closure
        let needsPush: Bool = try SessionUtil
            .config(
                for: variant,
                publicKey: publicKey
            )
            .mutate { conf in
                guard conf != nil else { throw SessionUtilError.nilConfigObject }
                
                // Peform the change
                try change(conf)
                
                // If we don't need to dump the data the we can finish early
                guard config_needs_dump(conf) else { return config_needs_push(conf) }
                
                try SessionUtil.createDump(
                    conf: conf,
                    for: variant,
                    publicKey: publicKey
                )?.save(db)
                
                return config_needs_push(conf)
            }
        
        // Make sure we need a push before scheduling one
        guard needsPush else { return }
        
        db.afterNextTransactionNestedOnce(dedupeId: SessionUtil.syncDedupeId(publicKey)) { db in
            ConfigurationSyncJob.enqueue(db, publicKey: publicKey)
        }
    }
    
    @discardableResult static func updatingThreads<T>(_ db: Database, _ updated: [T]) throws -> [T] {
        guard let updatedThreads: [SessionThread] = updated as? [SessionThread] else {
            throw StorageError.generic
        }
        
        // If we have no updated threads then no need to continue
        guard !updatedThreads.isEmpty else { return updated }
        
        let userPublicKey: String = getUserHexEncodedPublicKey(db)
        let groupedThreads: [SessionThread.Variant: [SessionThread]] = updatedThreads
            .grouped(by: \.variant)
        let urlInfo: [String: OpenGroupUrlInfo] = try OpenGroupUrlInfo
            .fetchAll(db, ids: updatedThreads.map { $0.id })
            .reduce(into: [:]) { result, next in result[next.threadId] = next }
        
        do {
            // Update the unread state for the threads first (just in case that's what changed)
            try SessionUtil.updateMarkedAsUnreadState(db, threads: updatedThreads)
            
            // Then update the `hidden` and `priority` values
            try groupedThreads.forEach { variant, threads in
                switch variant {
                    case .contact:
                        // If the 'Note to Self' conversation is pinned then we need to custom handle it
                        // first as it's part of the UserProfile config
                        if let noteToSelf: SessionThread = threads.first(where: { $0.id == userPublicKey }) {
                            try SessionUtil.performAndPushChange(
                                db,
                                for: .userProfile,
                                publicKey: userPublicKey
                            ) { conf in
                                try SessionUtil.updateNoteToSelf(
                                    db,
                                    priority: noteToSelf.pinnedPriority
                                        .map { Int32($0 == 0 ? 0 : max($0, 1)) }
                                        .defaulting(to: 0),
                                    hidden: noteToSelf.shouldBeVisible,
                                    in: conf
                                )
                            }
                        }
                        
                        // Remove the 'Note to Self' convo from the list for updating contact priorities
                        let remainingThreads: [SessionThread] = threads.filter { $0.id != userPublicKey }
                        
                        guard !remainingThreads.isEmpty else { return }
                        
                        try SessionUtil.performAndPushChange(
                            db,
                            for: .contacts,
                            publicKey: userPublicKey
                        ) { conf in
                            try SessionUtil.upsert(
                                contactData: remainingThreads
                                    .map { thread in
                                        SyncedContactInfo(
                                            id: thread.id,
                                            priority: thread.pinnedPriority
                                                .map { Int32($0 == 0 ? 0 : max($0, 1)) }
                                                .defaulting(to: 0),
                                            hidden: thread.shouldBeVisible
                                        )
                                    },
                                in: conf
                            )
                        }
                        
                    case .community:
                        try SessionUtil.performAndPushChange(
                            db,
                            for: .userGroups,
                            publicKey: userPublicKey
                        ) { conf in
                            try SessionUtil.upsert(
                                communities: threads
                                    .compactMap { thread -> CommunityInfo? in
                                        urlInfo[thread.id].map { urlInfo in
                                            CommunityInfo(
                                                urlInfo: urlInfo,
                                                priority: thread.pinnedPriority
                                                    .map { Int32($0 == 0 ? 0 : max($0, 1)) }
                                                    .defaulting(to: 0)
                                            )
                                        }
                                    },
                                in: conf
                            )
                        }
                        
                    case .legacyGroup:
                        try SessionUtil.performAndPushChange(
                            db,
                            for: .userGroups,
                            publicKey: userPublicKey
                        ) { conf in
                            try SessionUtil.upsert(
                                legacyGroups: threads
                                    .map { thread in
                                        LegacyGroupInfo(
                                            id: thread.id,
                                            hidden: thread.shouldBeVisible,
                                            priority: thread.pinnedPriority
                                                .map { Int32($0 == 0 ? 0 : max($0, 1)) }
                                                .defaulting(to: 0)
                                        )
                                    },
                                in: conf
                            )
                        }
                    
                    case .group:
                        // TODO: Add this
                        break
                }
            }
        }
        catch {
            SNLog("[libSession-util] Failed to dump updated data")
        }
        
        return updated
    }
}

// MARK: - ColumnKey

internal extension SessionUtil {
    struct ColumnKey: Equatable, Hashable {
        let sourceType: Any.Type
        let columnName: String
        
        init(_ column: ColumnExpression) {
            self.sourceType = type(of: column)
            self.columnName = column.name
        }
        
        func hash(into hasher: inout Hasher) {
            ObjectIdentifier(sourceType).hash(into: &hasher)
            columnName.hash(into: &hasher)
        }
        
        static func == (lhs: ColumnKey, rhs: ColumnKey) -> Bool {
            return (
                lhs.sourceType == rhs.sourceType &&
                lhs.columnName == rhs.columnName
            )
        }
    }
}

// MARK: - PriorityVisibilityInfo

extension SessionUtil {
    struct PriorityVisibilityInfo: Codable, FetchableRecord, Identifiable {
        let id: String
        let variant: SessionThread.Variant
        let pinnedPriority: Int32?
        let shouldBeVisible: Bool
    }
}
