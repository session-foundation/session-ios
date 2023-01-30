// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionUtilitiesKit

extension SessionCarouselView {
    public struct Info {
        let slices: [UIView]
        let sliceSize: CGSize
        let sliceCount: Int
        let shouldShowPageControl: Bool
        let pageControlHeight: CGFloat
        let pageControlScale: CGFloat // This is to control the size of the dots
        let shouldShowArrows: Bool
        let arrowsSize: CGSize
        
        // MARK: - Initialization
        
        init(
            slices: [UIView] = [],
            sliceSize: CGSize = .zero,
            shouldShowPageControl: Bool = true,
            pageControlHeight: CGFloat = 0,
            pageControlScale: CGFloat = 1,
            shouldShowArrows: Bool = true,
            arrowsSize: CGSize = .zero
        ) {
            self.slices = slices
            self.sliceSize = sliceSize
            self.sliceCount = slices.count
            self.shouldShowPageControl = shouldShowPageControl && (self.sliceCount > 1)
            self.pageControlHeight = pageControlHeight
            self.pageControlScale = pageControlScale
            self.shouldShowArrows = shouldShowArrows && (self.sliceCount > 1)
            self.arrowsSize = arrowsSize
        }
    }
}
