// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public protocol SessionCarouselViewDelegate: AnyObject {
    func carouselViewDidScrollToNewSlice(currentPage: Int)
}
