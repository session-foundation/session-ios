// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

public extension MutablePersistableRecord where Self: FetchableRecord {
    @discardableResult func upserted(_ db: ObservingDatabase) throws -> Self {
        var mutableSelf: Self = self
        try mutableSelf.upsert(db)
        return mutableSelf
    }
}
