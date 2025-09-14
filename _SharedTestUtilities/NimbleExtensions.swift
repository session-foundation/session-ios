// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Nimble

public extension SyncExpectation {
    func retrieveValue() async -> Value? {
        return try? expression.evaluate()
    }
}

public extension AsyncExpectation {
    func retrieveValue() async -> Value? {
        return try? await expression.evaluate()
    }
}
