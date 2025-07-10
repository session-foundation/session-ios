// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

@testable import SessionUtilitiesKit

public extension MutablePersistableRecord where Self: MutableIdentifiable {
    /// This is a test method which allows for inserting with a pre-defined id
    mutating func insert(_ db: ObservingDatabase, withRowId rowId: ID) throws {
        self.setId(rowId)
        try insert(db)
    }
}
