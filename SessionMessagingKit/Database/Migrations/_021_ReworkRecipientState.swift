// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

enum _021_ReworkRecipientState: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "ReworkRecipientState"
    static let minExpectedRunDuration: TimeInterval = 0.1
    static let createdTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        /// First we need to add the new columns to the `Interaction` table
        try db.alter(table: "interaction") { t in
            t.add(column: "state", .integer)
                .notNull()
                .indexed()                                            // Quicker querying
                .defaults(to: Interaction.State.sending.rawValue)
            t.add(column: "recipientReadTimestampMs", .integer)
            t.add(column: "mostRecentFailureText", .text)
        }
        
        /// As part of this change we have added two new `State` types: `deleted` and `localOnly` which
        /// will simplify some querying and logic for behaviours which have multiple `Interaction.Variant` cases
        try db.execute(sql: """
            UPDATE interaction
            SET state = \(Interaction.State.deleted.rawValue)
            WHERE variant = \(Interaction.Variant.standardIncomingDeleted.rawValue)
        """)
        try db.execute(sql: """
            UPDATE interaction
            SET state = \(Interaction.State.localOnly.rawValue)
            WHERE variant IN (\(Interaction.Variant.variantsWhichAreLocalOnly.map { "\($0.rawValue)" }.joined(separator: ", ")))
        """)
        
        /// Part of the logic in the `FailedMessageSendsJob` is to update all pending sends to be in the "failed" state but
        /// this migration will run before that gets the chance to so we need to trigger the same transition here to ensure that
        /// when we move the data from the old `recipientState` table across to the `Interaction` it's already in the
        /// correct state
        try db.execute(sql: """
            UPDATE recipientState
            SET state = 1    -- failed
            WHERE state = 0  -- sending
        """)
        try db.execute(sql: """
            UPDATE recipientState
            SET state = 4    -- failedToSync
            WHERE state = 5  -- syncing
        """)
        
        /// In the old logic there would be a `recipientState` for every participant in a `ClosedGroup` conversation and
        /// there were special rules around how to merge the states for display purposes so we want to replicate that
        /// behaviour here (the default `sending` state will be handled on the column itself so we only need to deal with
        /// other behaviours here)
        let recipientStateInfo: [Row] = try Row
            .fetchAll(db, sql: """
                SELECT
                    interactionId,
                    recipientId,
                    state,
                    readTimestampMs,
                    mostRecentFailureText
                FROM recipientState
            """)
            .grouped(by: { info -> Int64 in info["interactionId"] })
            .reduce(into: []) { result, next in
                guard next.value.count > 1 else {
                    result.append(contentsOf: next.value)
                    return
                }
                
                // If there is a single "failed" state, consider this message "failed"
                if let legacyInfo: Row = next.value.first(where: { $0["state"] == LegacyState.failed.rawValue }) {
                    result.append(legacyInfo)
                    return
                }
                
                // If there is a single "failedToSync" state, consider this message "failedToSync"
                if let legacyInfo: Row = next.value.first(where: { $0["state"] == LegacyState.failedToSync.rawValue }) {
                    result.append(legacyInfo)
                    return
                }
                
                // There isn't really a simple way to combine other combinations (the query would
                // pick the smallest, and there was UI logic which would just default to "sent") so
                // just go with the smallest
                result.append(next.value.sorted(by: { lhs, rhs in
                    let lhsState: Int = lhs["state"]
                    let rhsState: Int = rhs["state"]
                    
                    return (lhsState < rhsState)
                })[0])
            }
        
        /// Group the `recipientStates` by each of their properties so we can bulk update their associated
        /// interactions
        let recipientStatesByState: [Int: [Row]] = recipientStateInfo
            .grouped(by: { info -> Int in info["state"] })
        let recipientStatesByMostRecentFailureText: [String?: [Row]] = recipientStateInfo
            .filter { legacyState in legacyState["mostRecentFailureText"] != nil } // Filter out nulls
            .filter { legacyState in legacyState["state"] != LegacyState.sent.rawValue } // No need to keep failure text after send
            .grouped(by: { info -> String in info["mostRecentFailureText"] })
        
        /// Add the `state` and `mostRecentFailureText` values directly to their interactions
        try recipientStatesByState.forEach { rawLegacyState, states in
            guard let legacyState: LegacyState = LegacyState(rawValue: rawLegacyState) else { return }
            
            try db.execute(sql: """
                UPDATE interaction
                SET state = \(legacyState.interactionState.rawValue)
                WHERE id IN (\(states
                    .compactMap { $0["interactionId"].map { "\($0)" } }
                    .joined(separator: ", ")))
            """)
        }
        try recipientStatesByMostRecentFailureText.forEach { failureText, states in
            guard let failureText: String = failureText else { return }
            
            try db.execute(sql: """
                UPDATE interaction
                SET mostRecentFailureText = '\(failureText)'
                WHERE id IN (\(states
                    .compactMap { $0["interactionId"].map { "\($0)" } }
                    .joined(separator: ", ")))
            """)
        }
        
        /// Any interactions which didn't have a `recipientState` or a `MessageSendJob` should be considered `sent` (as
        /// the old UI behaviour was to render any messages without a `recipientState` as `sent`)
        var interactionIdsWithMessageSendJobs: Set<Int64> = []
        
        /// Only fetch from the `jobs` table if it exists or we aren't running tests (when running tests this allows us to skip running the
        /// SNUtilitiesKit migrations)
        if !SNUtilitiesKit.isRunningTests || ((try? db.tableExists("job")) == true) {
            interactionIdsWithMessageSendJobs = try Int64.fetchSet(db, sql: """
                SELECT interactionId
                FROM job
                WHERE (
                    variant = \(Job.Variant.messageSend.rawValue) AND
                    interactionId IS NOT NULL
                )
            """)
        }
        
        let interactionIdsToExclude: Set<Int64> = Set(recipientStateInfo
            .map { info -> Int64 in info["interactionId"] })
            .union(interactionIdsWithMessageSendJobs)
        if !interactionIdsToExclude.isEmpty {
            try db.execute(sql: """
                UPDATE interaction
                SET state = \(Interaction.State.sent.rawValue)
                WHERE id NOT IN (\(interactionIdsToExclude.map { "\($0)" }.joined(separator: ", ")))
            """)
        }
        else {
            try db.execute(sql: "UPDATE interaction SET state = \(Interaction.State.sent.rawValue)")
        }
        
        /// The timestamps are unlikely to have duplicates so we just need to add those individually
        try recipientStateInfo
            .filter { $0["readTimestampMs"] != nil }
            .forEach { state in
                guard
                    let interactionId: Int64 = state["interactionId"],
                    let readTimestampMs: Int64 = state["readTimestampMs"]
                else { return }
                
                try db.execute(sql: """
                    UPDATE interaction
                    SET recipientReadTimestampMs = \(readTimestampMs)
                    WHERE id = \(interactionId)
                """)
            }
        
        /// Finally we can drop the old recipient states table
        try db.drop(table: "recipientState")
        
        MigrationExecution.updateProgress(1)
    }
}

private extension _021_ReworkRecipientState {
    enum LegacyState: Int {
        case sending
        case failed
        case skipped
        case sent
        case failedToSync
        case syncing
        
        var interactionState: Interaction.State {
            switch self {
                case .sending: return .sending
                case .failed: return .failed
                case .skipped: return .failed    // Have removed the 'skipped' status
                case .sent: return .sent
                case .failedToSync: return .failedToSync
                case .syncing: return .syncing
            }
        }
    }
}
