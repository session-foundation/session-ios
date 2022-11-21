// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit

final class PagedScrollView: UIView, UIScrollViewDelegate {
    private static let autoScrollingTimeInterval: TimeInterval = 10
    private var slides: [UIView] = []
    private var slideSize: CGSize = .zero
    private var shouldAutoScroll: Bool = false
    private var timer: Timer?
    
    private lazy var contentWidth = stackView.set(.width, to: 0)
    private lazy var contentHeight = stackView.set(.height, to: 0)
    
    private var shouldArrowsShow: Bool = false {
        didSet {
            arrowLeft.isHidden = !shouldArrowsShow
            arrowRight.isHidden = !shouldArrowsShow
        }
    }
    
    // MARK: - UI Components
    
    private lazy var scrollView: UIScrollView = {
        let result = UIScrollView(frame: .zero)
        result.isPagingEnabled = true
        result.showsVerticalScrollIndicator = false
        result.showsHorizontalScrollIndicator = false
        result.delegate = self
        
        return result
    }()
    
    private lazy var stackView: UIStackView = {
        let result = UIStackView()
        result.axis = .horizontal
        
        return result
    }()
    
    private lazy var pageControl: UIPageControl = {
        let result = UIPageControl(frame: .zero)
        result.themeCurrentPageIndicatorTintColor = .textPrimary
        result.themePageIndicatorTintColor = .textSecondary
        result.themeTintColor = .textPrimary
        result.set(.height, to: 5)
        result.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
        return result
    }()
    
    private lazy var arrowLeft: UIImageView = {
        let result = UIImageView(image: UIImage(systemName: "chevron.left")?.withRenderingMode(.alwaysTemplate))
        result.themeTintColor = .textPrimary
        result.set(.height, to: 10)
        result.set(.width, to: 5)
        return result
    }()
    
    private lazy var arrowRight: UIImageView = {
        let result = UIImageView(image: UIImage(systemName: "chevron.right")?.withRenderingMode(.alwaysTemplate))
        result.themeTintColor = .textPrimary
        result.set(.height, to: 10)
        result.set(.width, to: 5)
        return result
    }()
    
    // MARK: - Initialization
    
    init(slides: [UIView] = [], slideSize: CGSize = .zero, shouldAutoScroll: Bool = false) {
        super.init(frame: .zero)
        setUpViewHierarchy()
        self.update(with: slides, slideSize: slideSize, shouldAutoScroll: shouldAutoScroll)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Content
    
    public func update(with slides: [UIView] = [], slideSize: CGSize = .zero, shouldAutoScroll: Bool = false) {
        self.slides = slides
        self.slideSize = slideSize
        self.shouldAutoScroll = shouldAutoScroll
        self.shouldArrowsShow = slides.count > 1
        
        pageControl.numberOfPages = slides.count
        pageControl.currentPage = 0
        pageControl.isHidden = (slides.count == 1)
        
        let contentSize = CGSize(width: slideSize.width * CGFloat(slides.count), height: slideSize.height)
        scrollView.contentSize = contentSize
        contentWidth.constant = contentSize.width
        contentHeight.constant = contentSize.height
        
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        
        self.slides.forEach {
            let wrapper: UIView = UIView()
            wrapper.set(.width, to: slideSize.width)
            wrapper.set(.height, to: slideSize.height)
            wrapper.addSubview($0)
            $0.center(in: wrapper)
            stackView.addArrangedSubview(wrapper)
        }
        
        if self.shouldAutoScroll {
            startScrolling()
        }
    }
    
    private func setUpViewHierarchy() {
        addSubview(scrollView)
        scrollView.pin(to: self)
        
        addSubview(arrowLeft)
        arrowLeft.pin(.left, to: .left, of: self)
        arrowLeft.center(.vertical, in: self, withInset: -2)
        
        addSubview(arrowRight)
        arrowRight.pin(.right, to: .right, of: self)
        arrowRight.center(.vertical, in: self, withInset: -2)
        
        addSubview(pageControl)
        pageControl.center(.horizontal, in: self)
        pageControl.pin(.bottom, to: .bottom, of: self, withInset: -1)
        
        scrollView.addSubview(stackView)
    }
    
    private func startScrolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimerOnMainThread(withTimeInterval: Self.autoScrollingTimeInterval, repeats: true) { _ in
            guard self.slides.count != 0 else { return }
            let targetPage = (self.pageControl.currentPage + 1) % self.slides.count
            self.scrollView.scrollRectToVisible(
                CGRect(
                    origin: CGPoint(
                        x: Int(self.slideSize.width) * targetPage,
                        y: 0
                    ),
                    size: self.slideSize
                ),
                animated: true
            )
        }
    }
    
    private func stopScrolling() {
        timer?.invalidate()
        timer = nil
    }
    
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let pageIndex = round(scrollView.contentOffset.x/slideSize.width)
        pageControl.currentPage = Int(pageIndex)
    }
}
