// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public enum SNUtilitiesKit {
    public private(set) static var maxFileSize: UInt = 0
    public private(set) static var maxValidImageDimension: Int = 0

    public static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil   // stringlint:ignore
    }

    public static func configure(
        networkMaxFileSize: UInt,
        maxValidImageDimention: Int,
        using dependencies: Dependencies
    ) {
        self.maxFileSize = networkMaxFileSize
        self.maxValidImageDimension = maxValidImageDimention
    }
}
