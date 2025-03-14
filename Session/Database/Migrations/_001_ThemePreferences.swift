// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import GRDB
import SessionUIKit
import SessionUtilitiesKit

/// This migration extracts an old theme preference from UserDefaults and saves it to the database as well as set the default for the other
/// theme preferences
///
/// **Note:** This migration used to live within `SessionUIKit` but we wanted to isolate it and remove dependencies from it so we
/// needed to extract this migration into the `Session` and `SessionShareExtension` targets (since both need theming they both
/// need to provide this migration as an option during setup)
enum _001_ThemePreferences: Migration {
    static let target: TargetMigrations.Identifier = ._deprecatedUIKit
    static let identifier: String = "ThemePreferences"
    static let minExpectedRunDuration: TimeInterval = 0.1
    static let createdTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: Database, using dependencies: Dependencies) throws {
        // Determine if the user was matching the system setting (previously the absence of this value
        // indicated that the app should match the system setting)
        let isExistingUser: Bool = MigrationHelper.userExists(db)
        let hadCustomLegacyThemeSetting: Bool = UserDefaults.standard.dictionaryRepresentation()
            .keys
            .contains("appMode")
        var matchSystemNightModeSetting: Bool = (isExistingUser && !hadCustomLegacyThemeSetting)
        let targetTheme: Theme = (!hadCustomLegacyThemeSetting ?
            Theme.classicDark :
            (UserDefaults.standard.integer(forKey: "appMode") == 0 ?
                Theme.classicLight :
                Theme.classicDark
            )
        )
        let targetPrimaryColor: Theme.PrimaryColor = .green
        
        // Save the settings
        try db.execute(sql: """
            DELETE FROM setting
            WHERE key IN ('themeMatchSystemDayNightCycle', 'selectedTheme', 'selectedThemePrimaryColor')
        """)
        
        let matchSystemNightModeSettingAsData: Data = withUnsafeBytes(of: &matchSystemNightModeSetting) { Data($0) }
        try db.execute(
            sql: """
                INSERT INTO setting (key, value)
                VALUES
                    ('themeMatchSystemDayNightCycle', ?),
                    ('selectedTheme', ?),
                    ('selectedThemePrimaryColor', ?)
            """,
            arguments: [
                matchSystemNightModeSettingAsData,
                targetTheme.rawValue.data(using: .utf8),
                targetPrimaryColor.rawValue.data(using: .utf8)
            ]
        )
        
        Storage.update(progress: 1, for: self, in: target, using: dependencies)
    }
}

extension Theme: @retroactive EnumStringSetting {}
extension Theme.PrimaryColor: @retroactive EnumStringSetting {}

enum DeprecatedUIKitMigrationTarget: MigratableTarget {
    public static func migrations() -> TargetMigrations {
        return TargetMigrations(
            identifier: ._deprecatedUIKit,
            migrations: [
                // Want to ensure the initial DB stuff has been completed before doing any
                // SNUIKit migrations
                [], // Initial DB Creation
                [], // YDB to GRDB Migration
                [], // Legacy DB removal
                [
                    _001_ThemePreferences.self
                ]
            ]
        )
    }
}
