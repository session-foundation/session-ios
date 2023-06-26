// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import DifferenceKit

public class SessionVersion {
    public enum FeatureVersion: Int, Codable, Equatable, Hashable, DatabaseValueConvertible {
        case legacyDisappearingMessages
        case newDisappearingMessages
    }
}
