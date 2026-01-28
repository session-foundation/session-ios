// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension Collection {
    func grouped<Key: Hashable>(by keyForValue: (Element) throws -> Key) -> [Key: [Element]] {
        return ((try? Dictionary(grouping: self, by: keyForValue)) ?? [:])
    }
}
