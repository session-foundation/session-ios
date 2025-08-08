// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import UIKit.UIFont
import GRDB

public enum SNUtilitiesKit {
    public static var maxFileSize: UInt = 0
    public static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil   // stringlint:ignore
    }

    public static func configure(
        networkMaxFileSize: UInt,
        using dependencies: Dependencies
    ) {
        self.maxFileSize = networkMaxFileSize
        
        // Register any recurring jobs to ensure they are actually scheduled
        dependencies[singleton: .jobRunner].registerRecurringJobs(
            scheduleInfo: [
                (.syncPushTokens, .recurringOnLaunch, false, false),
                (.syncPushTokens, .recurringOnActive, false, true)
            ]
        )
    }
}
