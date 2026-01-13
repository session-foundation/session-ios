// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import DifferenceKit

public extension ArraySection {
    func appending(_ element: Element) -> ArraySection {
        return appending(contentsOf: [element])
    }
    
    func appending(contentsOf elements: [Element]) -> ArraySection {
        return ArraySection(
            model: model,
            elements: self.elements + elements
        )
    }
}
