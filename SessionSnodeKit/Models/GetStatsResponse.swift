// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

extension SnodeAPI {
    public struct GetStatsResponse: Codable {
        private enum CodingKeys: String, CodingKey {
            case versionString = "version"
        }
        
        let versionString: String?
        
        var version: Version? { versionString.map { Version.from($0) } }
    }
}
