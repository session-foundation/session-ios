// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public extension LoadPageEvent {
    func target<ID>(with current: PagedData.LoadResult<ID>) -> PagedData.Target<ID>? {
        switch target {
            case .initial: return .initial
            case .nextPage(let lastIndex):
                guard lastIndex == current.info.lastIndex else { return nil }
                
                return .pageAfter
                
            case .previousPage(let firstIndex):
                guard firstIndex == current.info.firstPageOffset else { return nil }
                
                return .pageBefore
        }
    }
}
