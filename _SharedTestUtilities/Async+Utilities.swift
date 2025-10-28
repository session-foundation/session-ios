// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension AsyncStream {
    static func singleValue(value: Element) -> AsyncStream<Element> {
        var hasEmittedValue: Bool = false

        return AsyncStream(unfolding: {
            guard !hasEmittedValue else { return nil }
        
            hasEmittedValue = true
            return value
        })
    }
}
