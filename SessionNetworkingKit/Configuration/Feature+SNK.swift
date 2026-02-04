// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public extension FeatureStorage {
    static let onionRequestMinStandardPaths: FeatureConfig<Int> = Dependencies.create(
        identifier: "onionRequestMinStandardPaths",
        defaultOption: -1
    )
    
    static let onionRequestMinFilePaths: FeatureConfig<Int> = Dependencies.create(
        identifier: "onionRequestMinFilePaths",
        defaultOption: -1
    )
    
    static let quicMaxStandardStreams: FeatureConfig<Int> = Dependencies.create(
        identifier: "quicMaxStandardStreams",
        defaultOption: -1
    )
    
    static let quicMaxFileStreams: FeatureConfig<Int> = Dependencies.create(
        identifier: "quicMaxFileStreams",
        defaultOption: -1
    )
}
