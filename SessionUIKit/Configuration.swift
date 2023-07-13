// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

public enum SNUIKit: MigratableTarget {
    public static func migrations(_ db: Database) -> TargetMigrations {
        return TargetMigrations(
            identifier: .uiKit,
            migrations: [
                // Want to ensure the initial DB stuff has been completed before doing any
                // SNUIKit migrations
                [], // Initial DB Creation
                [], // YDB to GRDB Migration
                [], // YDB Removal
                [
                    _001_ThemePreferences.self
                ]   // Add job priorities
            ]
        )
    }
    
    public static func configure() {
    }
}
