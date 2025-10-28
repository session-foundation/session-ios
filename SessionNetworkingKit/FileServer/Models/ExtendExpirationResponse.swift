// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension Network.FileServer {
    struct ExtendExpirationResponse: Codable {
        public let size: Int
        public let uploaded: TimeInterval
        public let expires: TimeInterval
        
        public init(size: Int, uploaded: TimeInterval, expires: TimeInterval) {
            self.size = size
            self.uploaded = uploaded
            self.expires = expires
        }
    }
}
