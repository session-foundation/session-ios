// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

enum _047_DropUnneededColumnsAndTables: Migration {
    static let identifier: String = "DropUnneededColumnsAndTables"
    static let minExpectedRunDuration: TimeInterval = 0.1
    static var createdTables: [(FetchableRecord & TableRecord).Type] = []
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        /// This is now handled entirely in memory (previously we had this in the database because UI updates were driven by database
        /// changes, but now they are driven via our even observation system - removing this from the database means we no longer need
        /// to deal with cleaning up entries on launch as well)
        try db.drop(table: "threadTypingIndicator")
        
        try db.alter(table: "openGroup") { t in
            /// We previously stored the "default" communities in the database as, in the past, we wanted to show them immediately
            /// regardless of whether we have network connectivity - that changed a while back where we now only want to show them
            /// if they are "correct"
            ///
            /// Instead of removing this column we are repurposing it to `shouldPoll` as, while we don't currently have a mechanism
            /// to disable polling a comminuty, it's likley adding one in the future would be beneficial
            t.rename(column: "isActive", to: "shouldPoll")
        }
        
        /// When we were storing the "default" communities we added an entry to the database which had an empty `roomToken`, as
        /// a result we needed a bunch of checks to ensure we wouldn't include this when doing any operations related to the communities
        /// explicitly joined by the user
        ///
        /// Now that these "default" communities exist solely in memory we can discard these entries
        try OpenGroup.filter(OpenGroup.Columns.roomToken == "").deleteAll(db)
        
        MigrationExecution.updateProgress(1)
    }
}
