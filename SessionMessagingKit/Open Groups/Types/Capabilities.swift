// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

extension Network.SOGS {
    public struct Capabilities: Codable, Equatable {
        public let capabilities: [Network.SOGS.Capability.Variant]
        public let missing: [Network.SOGS.Capability.Variant]?

        // MARK: - Initialization

        public init(capabilities: [Network.SOGS.Capability.Variant], missing: [Network.SOGS.Capability.Variant]? = nil) {
            self.capabilities = capabilities
            self.missing = missing
        }
    }
}
