// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionUtilitiesKit

final class SessionCarouselView: UIView, UIScrollViewDelegate {
    private let slicesForLoop: [UIView]
    private let info: SessionCarouselView.Info
    var delegate: SessionCarouselViewDelegate?
    
    // MARK: - UI
    private lazy var scrollView: UIScrollView = {
        let result: UIScrollView = UIScrollView()
        result.delegate = self
        result.isPagingEnabled = true
        result.showsHorizontalScrollIndicator = false
        result.showsVerticalScrollIndicator = false
        result.contentSize = CGSize(
            width: self.info.sliceSize.width * CGFloat(self.slicesForLoop.count),
            height: self.info.sliceSize.height
        )
        result.layer.cornerRadius = self.info.cornerRadius
        result.layer.masksToBounds = true
        
        return result
    }()
    
    private lazy var pageControl: UIPageControl = {
        let result: UIPageControl = UIPageControl()
        result.numberOfPages = self.info.sliceCount
        result.currentPage = 0
        result.isHidden = !self.info.shouldShowPageControl
        result.transform = CGAffineTransform(
            scaleX: self.info.pageControlStyle.size.rawValue,
            y: self.info.pageControlStyle.size.rawValue
        )
        
        return result
    }()
    
    private lazy var arrowLeft: UIButton = {
        let result = UIButton(type: .custom)
        result.setImage(UIImage(systemName: "chevron.left")?.withRenderingMode(.alwaysTemplate), for: .normal)
        result.addTarget(self, action: #selector(scrollToPreviousSlice), for: .touchUpInside)
        result.themeTintColor = .textPrimary
        result.set(.width, to: self.info.arrowsSize.width)
        result.set(.height, to: self.info.arrowsSize.height)
        result.isHidden = !self.info.shouldShowArrows
        
        return result
    }()

    private lazy var arrowRight: UIButton = {
        let result = UIButton(type: .custom)
        result.setImage(UIImage(systemName: "chevron.right")?.withRenderingMode(.alwaysTemplate), for: .normal)
        result.addTarget(self, action: #selector(scrollToNextSlice), for: .touchUpInside)
        result.themeTintColor = .textPrimary
        result.set(.width, to: self.info.arrowsSize.width)
        result.set(.height, to: self.info.arrowsSize.height)
        result.isHidden = !self.info.shouldShowArrows
        
        return result
    }()
    
    // MARK: - Lifecycle
    
    init(info: SessionCarouselView.Info) {
        self.info = info
        if self.info.sliceCount > 1,
           let copyOfFirstSlice: UIView = self.info.copyOfFirstSlice,
           let copyOfLastSlice: UIView = self.info.copyOfLastSlice
        {
            self.slicesForLoop = [copyOfLastSlice]
                .appending(contentsOf: self.info.slices)
                .appending(copyOfFirstSlice)
        } else {
            self.slicesForLoop = self.info.slices
        }
        
        super.init(frame: CGRect.zero)
        setUpViewHierarchy()
    }

    override init(frame: CGRect) {
        preconditionFailure("Use init(attachment:) instead.")
    }

    required init?(coder: NSCoder) {
        preconditionFailure("Use init(attachment:) instead.")
    }

    private func setUpViewHierarchy() {
        set(.width, to: self.info.sliceSize.width + Values.largeSpacing + 2 * self.info.arrowsSize.width)
        set(.height, to: self.info.sliceSize.height)
        
        let stackView: UIStackView = UIStackView(arrangedSubviews: self.slicesForLoop)
        stackView.axis = .horizontal
        stackView.set(.width, to: self.info.sliceSize.width * CGFloat(self.slicesForLoop.count))
        stackView.set(.height, to: self.info.sliceSize.height)
        
        addSubview(self.scrollView)
        scrollView.center(in: self)
        scrollView.set(.width, to: self.info.sliceSize.width)
        scrollView.set(.height, to: self.info.sliceSize.height)
        scrollView.addSubview(stackView)
        scrollView.setContentOffset(
            CGPoint(
                x: Int(self.info.sliceSize.width) * (self.info.sliceCount > 1 ? 1 : 0),
                y: 0
            ),
            animated: false
        )
        
        addSubview(self.pageControl)
        self.pageControl.center(.horizontal, in: self)
        self.pageControl.pin(.bottom, to: .bottom, of: self)
        
        addSubview(self.arrowLeft)
        self.arrowLeft.pin(.leading, to: .leading, of: self)
        self.arrowLeft.center(.vertical, in: self)
        
        addSubview(self.arrowRight)
        self.arrowRight.pin(.trailing, to: .trailing, of: self)
        self.arrowRight.center(.vertical, in: self)
    }
    
    // MARK: - UIScrollViewDelegate
    
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let pageIndex: Int = {
            let maybeCurrentPageIndex: Int = Int(round(scrollView.contentOffset.x/self.info.sliceSize.width))
            if self.info.sliceCount > 1 {
                if maybeCurrentPageIndex == 0 {
                    return pageControl.numberOfPages - 1
                }
                if maybeCurrentPageIndex == self.slicesForLoop.count - 1 {
                    return 0
                }
                return maybeCurrentPageIndex - 1
            }
            return maybeCurrentPageIndex
        }()

        pageControl.currentPage = pageIndex
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        setCorrectCotentOffsetIfNeeded(scrollView)
        delegate?.carouselViewDidScrollToNewSlice(currentPage: pageControl.currentPage)
    }
    
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        setCorrectCotentOffsetIfNeeded(scrollView)
        delegate?.carouselViewDidScrollToNewSlice(currentPage: pageControl.currentPage)
    }
    
    private func setCorrectCotentOffsetIfNeeded(_ scrollView: UIScrollView) {
        if pageControl.currentPage == 0 {
            scrollView.setContentOffset(
                CGPoint(
                    x: Int(self.info.sliceSize.width) * 1,
                    y: 0
                ),
                animated: false
            )
        }

        if pageControl.currentPage == pageControl.numberOfPages - 1 {
            let realLastIndex: Int = self.slicesForLoop.count - 2
            scrollView.setContentOffset(
                CGPoint(
                    x: Int(self.info.sliceSize.width) * realLastIndex,
                    y: 0
                ),
                animated: false
            )
        }
    }
    
    // MARK: - Interaction
    
    @objc func scrollToNextSlice() {
        self.scrollView.setContentOffset(
            CGPoint(
                x: self.scrollView.contentOffset.x + self.info.sliceSize.width,
                y: 0
            ),
            animated: true
        )
    }
    
    @objc func scrollToPreviousSlice() {
        self.scrollView.setContentOffset(
            CGPoint(
                x: self.scrollView.contentOffset.x - self.info.sliceSize.width,
                y: 0
            ),
            animated: true
        )
    }
}
