// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

public enum SNUtilitiesKit: MigratableTarget { // Just to make the external API nice
    public static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    public static func migrations(_ db: Database) -> TargetMigrations {
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
                ],
                [], // Other DB migrations
                [], // Legacy DB removal
                [
                    _004_AddJobPriority.self
                ]
            ]
        )
    }

    public static func configure(maxFileSize: UInt) {
        SNUtilitiesKitConfiguration.maxFileSize = maxFileSize
    }
}

@objc public final class SNUtilitiesKitConfiguration: NSObject {
    @objc public static var maxFileSize: UInt = 0
    @objc public static var isRunningTests: Bool { return SNUtilitiesKit.isRunningTests }
}
