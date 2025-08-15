// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import UIKit.UIFont
import GRDB

public enum SNUtilitiesKit: MigratableTarget { // Just to make the external API nice
    public private(set) static var maxFileSize: UInt = 0
    public private(set) static var maxValidImageDimension: Int = 0
    public static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil   // stringlint:ignore
    }

    public static func migrations() -> TargetMigrations {
        return TargetMigrations(
            identifier: .utilitiesKit,
            migrations: [
                [
                    // Intentionally including the '_003_YDBToGRDBMigration' in the first migration
                    // set to ensure the 'Identity' data is migrated before any other migrations are
                    // run (some need access to the users publicKey)
                    _001_InitialSetupMigration.self,
                    _002_SetupStandardJobs.self,
                    _003_YDBToGRDBMigration.self
                ],  // Initial DB Creation
                [], // YDB to GRDB Migration
                [], // Legacy DB removal
                [
                    _004_AddJobPriority.self
                ],  // Add job priorities
                [], // Fix thread FTS
                [
                    _005_AddJobUniqueHash.self
                ],
                [
                    _006_RenameTableSettingToKeyValueStore.self
                ],  // Renamed `Setting` to `KeyValueStore`
                []
            ]
        )
    }

    public static func configure(
        networkMaxFileSize: UInt,
        maxValidImageDimention: Int,
        using dependencies: Dependencies
    ) {
        self.maxFileSize = networkMaxFileSize
        self.maxValidImageDimension = maxValidImageDimention
        
        // Register any recurring jobs to ensure they are actually scheduled
        dependencies[singleton: .jobRunner].registerRecurringJobs(
            scheduleInfo: [
                (.syncPushTokens, .recurringOnLaunch, false, false),
                (.syncPushTokens, .recurringOnActive, false, true)
            ]
        )
    }
}
