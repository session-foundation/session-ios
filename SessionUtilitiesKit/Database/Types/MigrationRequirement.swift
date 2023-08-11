// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
import Foundation

public enum MigrationRequirement: CaseIterable {
    case sessionUtilStateLoaded

    var shouldProcessAtCompletionIfNotRequired: Bool {
        switch self {
            case .sessionUtilStateLoaded: return true
        }
    }
}
