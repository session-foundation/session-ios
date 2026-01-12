// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension OptionSet {
    func inserting(_ other: Element?) -> Self {
        guard let other: Element = other else { return self }
        
        var result: Self = self
        result.insert(other)
        return result
    }
    
    func removing(_ other: Element) -> Self {
        var result: Self = self
        result.remove(other)
        return result
    }
}
