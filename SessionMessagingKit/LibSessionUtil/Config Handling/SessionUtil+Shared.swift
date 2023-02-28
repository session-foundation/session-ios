// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit

// MARK: - Convenience

internal extension SessionUtil {
    static func assignmentsRequireConfigUpdate(_ assignments: [ConfigColumnAssignment]) -> Bool {
        let targetColumns: Set<ColumnKey> = Set(assignments.map { ColumnKey($0.column) })
        let allColumnsThatTriggerConfigUpdate: Set<ColumnKey> = []
            .appending(contentsOf: columnsRelatedToUserProfile)
            .appending(contentsOf: columnsRelatedToContacts)
            .appending(contentsOf: columnsRelatedToConvoInfoVolatile)
            .map { ColumnKey($0) }
            .asSet()
        
        return !allColumnsThatTriggerConfigUpdate.isDisjoint(with: targetColumns)
    }
    /// This function assumes that the `pinnedPriority` values get set correctly elsewhere rather than trying to enforce
    /// uniqueness in here (this means if we eventually allow for "priority grouping" this logic wouldn't change - just where the
    /// priorities get updated in the HomeVC
    static func updateThreadPrioritiesIfNeeded<T>(
        _ db: Database,
        _ assignments: [ConfigColumnAssignment],
        _ updated: [T]
    ) throws {
        // Note: This logic assumes that the 'pinnedPriority' values get set correctly elsewhere
        // rather than trying to enforce uniqueness in here (this means if we eventually allow for
        // "priority grouping" this logic wouldn't change - just where the priorities get updated
        // in the HomeVC
        let userPublicKey: String = getUserHexEncodedPublicKey(db)
        let pinnedThreadInfo: [PriorityInfo] = try SessionThread
            .select(.id, .variant, .pinnedPriority)
            .asRequest(of: PriorityInfo.self)
            .fetchAll(db)
        let groupedPriorityInfo: [SessionThread.Variant: [PriorityInfo]] = pinnedThreadInfo
            .grouped(by: \.variant)
        let pinnedCommunities: [String: OpenGroupUrlInfo] = try OpenGroupUrlInfo
            .fetchAll(db, ids: pinnedThreadInfo.map { $0.id })
            .reduce(into: [:]) { result, next in result[next.threadId] = next }
        
        do {
            try groupedPriorityInfo.forEach { variant, priorityInfo in
                switch variant {
                    case .contact:
                        // If the 'Note to Self' conversation is pinned then we need to custom handle it
                        // first as it's part of the UserProfile config
                        if let noteToSelfPriority: PriorityInfo = priorityInfo.first(where: { $0.id == userPublicKey }) {
                            let atomicConf: Atomic<UnsafeMutablePointer<config_object>?> = SessionUtil.config(
                                for: .userProfile,
                                publicKey: userPublicKey
                            )
                            
                            try SessionUtil.updateNoteToSelfPriority(
                                db,
                                priority: Int32(noteToSelfPriority.pinnedPriority ?? 0),
                                in: atomicConf
                            )
                        }
                        
                        // Remove the 'Note to Self' convo from the list for updating contact priorities
                        let targetPriorities: [PriorityInfo] = priorityInfo.filter { $0.id != userPublicKey }
                        
                        guard !targetPriorities.isEmpty else { return }
                        
                        // Since we are doing direct memory manipulation we are using an `Atomic`
                        // type which has blocking access in it's `mutate` closure
                        try SessionUtil
                            .config(
                                for: .contacts,
                                publicKey: userPublicKey
                            )
                            .mutate { conf in
                                let result: ConfResult = try SessionUtil.upsert(
                                    contactData: targetPriorities
                                        .map { ($0.id, nil, nil, Int32($0.pinnedPriority ?? 0), nil) },
                                    in: conf
                                )
                                
                                // If we don't need to dump the data the we can finish early
                                guard result.needsDump else { return }
                                
                                try SessionUtil.createDump(
                                    conf: conf,
                                    for: .contacts,
                                    publicKey: userPublicKey
                                )?.save(db)
                            }
                        
                    case .community:
                        // Since we are doing direct memory manipulation we are using an `Atomic`
                        // type which has blocking access in it's `mutate` closure
                        try SessionUtil
                            .config(
                                for: .userGroups,
                                publicKey: userPublicKey
                            )
                            .mutate { conf in
                                let result: ConfResult = try SessionUtil.upsert(
                                    communities: priorityInfo
                                        .compactMap { info in
                                            guard let communityInfo: OpenGroupUrlInfo = pinnedCommunities[info.id] else {
                                                return nil
                                            }
                                            
                                            return (communityInfo, info.pinnedPriority)
                                        },
                                    in: conf
                                )
                                
                                // If we don't need to dump the data the we can finish early
                                guard result.needsDump else { return }
                                
                                try SessionUtil.createDump(
                                    conf: conf,
                                    for: .userGroups,
                                    publicKey: userPublicKey
                                )?.save(db)
                            }
                        
                    case .legacyGroup:
                        // Since we are doing direct memory manipulation we are using an `Atomic`
                        // type which has blocking access in it's `mutate` closure
                        try SessionUtil
                            .config(
                                for: .userGroups,
                                publicKey: userPublicKey
                            )
                            .mutate { conf in
                                let result: ConfResult = try SessionUtil.upsert(
                                    legacyGroups: priorityInfo
                                        .map { LegacyGroupInfo(id: $0.id, priority: $0.pinnedPriority) },
                                    in: conf
                                )
                                
                                // If we don't need to dump the data the we can finish early
                                guard result.needsDump else { return }
                                
                                try SessionUtil.createDump(
                                    conf: conf,
                                    for: .userGroups,
                                    publicKey: userPublicKey
                                )?.save(db)
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

// MARK: - Pinned Priority

extension SessionUtil {
    struct PriorityInfo: Codable, FetchableRecord, Identifiable {
        let id: String
        let variant: SessionThread.Variant
        let pinnedPriority: Int32?
    }
}
