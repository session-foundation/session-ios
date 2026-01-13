// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public extension LoadPageEvent {
    func target<ID>(with current: PagedData.LoadResult<ID>) -> PagedData.Target<ID>? {
        switch target {
            case .initial: return .initial
            case .initialPageAround(let erasedId):
                guard let id: ID = erasedId as? ID else { return .initial }
                
                return .initialPageAround(id: id)
                
            case .nextPage(let lastIndex):
                guard lastIndex == current.info.lastIndex else { return nil }
                
                return .pageAfter
                
            case .previousPage(let firstIndex):
                guard firstIndex == current.info.firstPageOffset else { return nil }
                
                return .pageBefore
                
            case .jumpTo(let erasedId, let padding):
                guard
                    let id: ID = erasedId as? ID,
                    !current.info.currentIds.contains(id)
                else { return nil }
                
                return .jumpTo(id: id, padding: padding)
        }
    }
}
