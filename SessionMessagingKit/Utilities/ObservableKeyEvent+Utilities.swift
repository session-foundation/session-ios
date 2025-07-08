// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public extension LoadPageEvent {
    func load<ID>(_ db: ObservingDatabase, current: PagedData.LoadResult<ID>) throws -> PagedData.LoadResult<ID> {
        switch target {
            case .initial:
                return try current.info
                    .load(db, .initial)
                    .prepending(existingNewRowIds: current.newRowIds)
                
            case .nextPage(let lastIndex):
                guard lastIndex == current.info.lastIndex else { return current }
                
                return try current.info
                    .load(db, .pageAfter)
                    .prepending(existingNewRowIds: current.newRowIds)
                
            case .previousPage(let firstIndex):
                guard firstIndex == current.info.firstPageOffset else { return current }
                
                return try current.info
                    .load(db, .pageBefore)
                    .prepending(existingNewRowIds: current.newRowIds)
        }
    }
}
