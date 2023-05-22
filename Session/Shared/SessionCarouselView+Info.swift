// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionUtilitiesKit

extension SessionCarouselView {
    public struct Info {
        let slices: [UIView]
        let copyOfFirstSlice: UIView?
        let copyOfLastSlice: UIView?
        let sliceSize: CGSize
        let sliceCount: Int
        let shouldShowPageControl: Bool
        let pageControlStyle: PageControlStyle
        let shouldShowArrows: Bool
        let arrowsSize: CGSize
        let cornerRadius: CGFloat
        
        // MARK: - Initialization
        
        init(
            slices: [UIView] = [],
            copyOfFirstSlice: UIView? = nil,
            copyOfLastSlice: UIView? = nil,
            sliceSize: CGSize = .zero,
            shouldShowPageControl: Bool = true,
            pageControlStyle: PageControlStyle,
            shouldShowArrows: Bool = true,
            arrowsSize: CGSize = .zero,
            cornerRadius: CGFloat = 0
        ) {
            self.slices = slices
            self.copyOfFirstSlice = copyOfFirstSlice
            self.copyOfLastSlice = copyOfLastSlice
            self.sliceSize = sliceSize
            self.sliceCount = slices.count
            self.shouldShowPageControl = shouldShowPageControl && (self.sliceCount > 1)
            self.pageControlStyle = pageControlStyle
            self.shouldShowArrows = shouldShowArrows && (self.sliceCount > 1)
            self.arrowsSize = arrowsSize
            self.cornerRadius = cornerRadius
        }
    }
    
    public struct PageControlStyle {
        enum DotSize: CGFloat {
            case mini = 0.5
            case medium = 0.8
            case original = 1
        }
        
        let height: CGFloat?
        let size: DotSize
        let backgroundColor: UIColor
        let bottomInset: CGFloat
        
        // MARK: - Initialization
        
        init(
            height: CGFloat? = nil,
            size: DotSize = .original,
            backgroundColor: UIColor = .clear,
            bottomInset: CGFloat = 0
        ) {
            self.height = height
            self.size = size
            self.backgroundColor = backgroundColor
            self.bottomInset = bottomInset
        }
    }
}
