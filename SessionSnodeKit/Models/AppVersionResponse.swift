// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

struct AppVersionResponse: Codable {
    enum CodingKeys: String, CodingKey {
        case version = "result"
    }
    
    public let version: String
}
