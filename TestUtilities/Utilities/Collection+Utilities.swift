// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension Collection {
    subscript(test index: Index) -> Element? {
        return (indices.contains(index) ? self[index] : nil)
    }
}
