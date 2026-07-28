// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

/// The Session Pro wire-format update renamed two `profile` columns and changed the proof-expiry unit:
/// - `proGenIndexHashHex` -> `proRevocationTagHex` (libsession renamed the field `gen_index_hash` -> `revocation_tag`)
/// - `proExpiryUnixTimestampMs` -> `proExpiryUnixTimestampSeconds` (the message-proof expiry is now whole unix
///   seconds, matching the wire/libsession and iOS's own clock; existing millisecond values are converted to
///   seconds by dividing by 1000)
///
/// Session Pro ships behind a feature flag, so `_048_SessionProChanges` already ran on live databases with the
/// old column names/units — hence this real migration rather than editing `_048` in place.
enum _053_RenameProColumnsForWireFormat: Migration {
    static let identifier: String = "RenameProColumnsForWireFormat"
    static let minExpectedRunDuration: TimeInterval = 0.1
    static var createdTables: [(FetchableRecord & TableRecord).Type] = []

    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        try db.alter(table: "profile") { t in
            t.rename(column: "proGenIndexHashHex", to: "proRevocationTagHex")
            t.rename(column: "proExpiryUnixTimestampMs", to: "proExpiryUnixTimestampSeconds")
        }

        /// Convert any existing millisecond expiry values to whole seconds (`0` stays `0`)
        try db.execute(sql: """
            UPDATE profile
            SET proExpiryUnixTimestampSeconds = proExpiryUnixTimestampSeconds / 1000
        """)

        MigrationExecution.updateProgress(1)
    }
}
