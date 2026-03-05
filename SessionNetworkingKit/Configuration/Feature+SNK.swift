// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public extension FeatureStorage {
    /// This feature should never be enabled outside of tests, it allows the `AttachmentDownloadJob` to run when there is
    /// already another job downloading the target attachment
    static let allowDuplicateDownloads: FeatureConfig<Bool> = Dependencies.create(
        identifier: "allowDuplicateDownloads"
    )
    
    /// This feature disables the timeouts for network requests (requests will keep going until they complete)
    static let disableNetworkRequestTimeouts: FeatureConfig<Bool> = Dependencies.create(
        identifier: "disableNetworkRequestTimeouts"
    )
    
    /// This feature controls the minimum number of standard paths (the default of `-1` means `libSession` decides)
    static let onionRequestMinStandardPaths: FeatureConfig<Int> = Dependencies.create(
        identifier: "onionRequestMinStandardPaths",
        defaultOption: -1
    )
    
    /// This feature controls the minimum number of file paths (the default of `-1` means `libSession` decides)
    static let onionRequestMinFilePaths: FeatureConfig<Int> = Dependencies.create(
        identifier: "onionRequestMinFilePaths",
        defaultOption: -1
    )
    
    /// This feature controls the minimum number of streams standard paths use (the default of `-1` means `libSession` decides)
    static let quicMaxStandardStreams: FeatureConfig<Int> = Dependencies.create(
        identifier: "quicMaxStandardStreams",
        defaultOption: -1
    )
    
    /// This feature controls the minimum number of streams file paths use (the default of `-1` means `libSession` decides)
    static let quicMaxFileStreams: FeatureConfig<Int> = Dependencies.create(
        identifier: "quicMaxFileStreams",
        defaultOption: -1
    )
}
