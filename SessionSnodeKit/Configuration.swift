// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

public enum SNSnodeKit: MigratableTarget { // Just to make the external API nice
    public static func migrations(_ db: Database) -> TargetMigrations {
        return TargetMigrations(
            identifier: .snodeKit,
            migrations: [
                [
                    _001_InitialSetupMigration.self,
                    _002_SetupStandardJobs.self
                ],
                [
                    _003_YDBToGRDBMigration.self
                ],
                [
                    _004_FlagMessageHashAsDeletedOrInvalid.self
                ],
                []  // Add job priorities
            ]
        )
    }

    public static func configure() {
        // Configure the job executors
        JobRunner.setExecutor(GetSnodePoolJob.self, for: .getSnodePool)
    }
}
