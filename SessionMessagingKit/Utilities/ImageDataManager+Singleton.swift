// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUIKit
import SessionUtilitiesKit

// MARK: - Singleton

public extension Singleton {
    static let imageDataManager: SingletonConfig<ImageDataManagerType> = Dependencies.create(
        identifier: "imageDataManager",
        createInstance: { _, _ in ImageDataManager() }
    )
}
