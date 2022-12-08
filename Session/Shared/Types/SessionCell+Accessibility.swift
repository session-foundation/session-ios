// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension SessionCell {
    struct Accessibility: Hashable, Equatable {
        let identifier: String?
        let label: String?
        
        public init(
            identifier: String? = nil,
            label: String? = nil
        ) {
            self.identifier = identifier
            self.label = label
        }
    }
}
