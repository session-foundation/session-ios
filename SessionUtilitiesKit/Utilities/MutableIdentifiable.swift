// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public protocol MutableIdentifiable: Identifiable {
    mutating func setId(_ id: ID)
}
