// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine

public extension Subscribers.Completion where Failure == Error {
    var errorOrNull: Error? {
        switch self {
            case .finished: return nil
            case .failure(let error): return error
        }
    }
}
