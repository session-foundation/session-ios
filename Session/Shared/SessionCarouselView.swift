// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

final class SessionCarouselView: UIView, UIScrollViewDelegate {
    private let slicesForLoop: [UIView]
    private let sliceSize: CGSize
    private let sliceCount: Int
    
    // MARK: - Settings
    public var showPageControl: Bool = true {
        didSet {
            self.pageControl.isHidden = !showPageControl
        }
    }
    
    // MARK: - UI
    private lazy var scrollView: UIScrollView = {
        let result: UIScrollView = UIScrollView()
        result.delegate = self
        result.isPagingEnabled = true
        result.showsHorizontalScrollIndicator = false
        result.showsVerticalScrollIndicator = false
        result.contentSize = CGSize(
            width: self.sliceSize.width * CGFloat(self.slicesForLoop.count),
            height: self.sliceSize.height
        )
        
        return result
    }()
    
    private lazy var pageControl: UIPageControl = {
        let result: UIPageControl = UIPageControl()
        result.numberOfPages = self.sliceCount
        result.currentPage = 0
        
        return result
    }()
    
    // MARK: - Lifecycle
    init(slices: [UIView], sliceSize: CGSize) {
        self.sliceCount = slices.count
        if self.sliceCount > 1, let copyOfFirstSlice: UIView = slices.first?.copyView(), let copyOfLastSlice: UIView = slices.last?.copyView() {
            self.slicesForLoop = [copyOfLastSlice]
                .appending(contentsOf: slices)
                .appending(copyOfFirstSlice)
        } else {
            self.slicesForLoop = slices
        }
        self.sliceSize = sliceSize
        
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
        let stackView: UIStackView = UIStackView(arrangedSubviews: self.slicesForLoop)
        stackView.axis = .horizontal
        stackView.set(.width, to: self.sliceSize.width * CGFloat(self.slicesForLoop.count))
        stackView.set(.height, to: self.sliceSize.height)
        
        addSubview(self.scrollView)
        scrollView.pin(to: self)
        scrollView.set(.width, to: self.sliceSize.width)
        scrollView.set(.height, to: self.sliceSize.height)
        scrollView.addSubview(stackView)
        scrollView.setContentOffset(
            CGPoint(
                x: Int(self.sliceSize.width) * (self.sliceCount > 1 ? 1 : 0),
                y: 0
            ),
            animated: false
        )
        
        addSubview(self.pageControl)
        self.pageControl.center(.horizontal, in: self)
        self.pageControl.pin(.bottom, to: .bottom, of: self)
    }
    
    // MARK: - UIScrollViewDelegate
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let pageIndex: Int = {
            let maybeCurrentPageIndex: Int = Int(round(scrollView.contentOffset.x/sliceSize.width))
            if self.sliceCount > 1 {
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
        if pageControl.currentPage == 0 {
            scrollView.setContentOffset(
                CGPoint(
                    x: Int(self.sliceSize.width) * 1,
                    y: 0
                ),
                animated: false
            )
        }

        if pageControl.currentPage == pageControl.numberOfPages - 1 {
            let realLastIndex: Int = self.slicesForLoop.count - 2
            scrollView.setContentOffset(
                CGPoint(
                    x: Int(self.sliceSize.width) * realLastIndex,
                    y: 0
                ),
                animated: false
            )
        }
    }
}
