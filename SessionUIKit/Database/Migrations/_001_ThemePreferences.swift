// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import GRDB
import SessionUtilitiesKit

/// This migration extracts an old theme preference from UserDefaults and saves it to the database as well as set the default for the other
/// theme preferences
enum _001_ThemePreferences: Migration {
    static let target: TargetMigrations.Identifier = .uiKit
    static let identifier: String = "ThemePreferences"
    static let needsConfigSync: Bool = false
    static let minExpectedRunDuration: TimeInterval = 0.1
    static let fetchedTables: [(TableRecord & FetchableRecord).Type] = [Identity.self]
    static let createdOrAlteredTables: [(TableRecord & FetchableRecord).Type] = []
    static let droppedTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: Database, using dependencies: Dependencies) throws {
        // Determine if the user was matching the system setting (previously the absence of this value
        // indicated that the app should match the system setting)
        let isExistingUser: Bool = Identity.userExists(db)
        let hadCustomLegacyThemeSetting: Bool = UserDefaults.standard.dictionaryRepresentation()
            .keys
            .contains("appMode")
        let matchSystemNightModeSetting: Bool = (isExistingUser && !hadCustomLegacyThemeSetting)
        let targetTheme: Theme = (!hadCustomLegacyThemeSetting ?
            Theme.classicDark :
            (UserDefaults.standard.integer(forKey: "appMode") == 0 ?
                Theme.classicLight :
                Theme.classicDark
            )
        )
        let targetPrimaryColor: Theme.PrimaryColor = .green
        
        // Save the settings
        db[.themeMatchSystemDayNightCycle] = matchSystemNightModeSetting
        db[.theme] = targetTheme
        db[.themePrimaryColor] = targetPrimaryColor
        
        // Looks like the ThemeManager will load it's default values before this migration gets run
        // as a result we need to update the ThemeManager to ensure the correct theme is applied
        ThemeManager.setInitialThemeState(
            theme: targetTheme,
            primaryColor: targetPrimaryColor,
            matchSystemNightModeSetting: matchSystemNightModeSetting
        )
        
        Storage.update(progress: 1, for: self, in: target) // In case this is the last migration
    }
}
