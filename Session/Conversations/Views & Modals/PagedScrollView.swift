// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit

final class PagedScrollView: UIView {
    private static let autoScrollingTimeInterval: TimeInterval = 3
    private var slides: [UIView] = []
    private var slideSize: CGSize = .zero
    private var shouldAutoScroll: Bool = false
    private var timer: Timer?
    
    // MARK: - UI Components
    
    private lazy var scrollView: UIScrollView = {
        let result = UIScrollView(frame: .zero)
        result.isPagingEnabled = true
        result.showsVerticalScrollIndicator = false
        result.showsHorizontalScrollIndicator = false
        
        return result
    }()
    
    private lazy var stackView: UIStackView = {
        let result = UIStackView()
        result.axis = .horizontal
        
        return result
    }()
    
    private lazy var pageControl: UIPageControl = {
        let result = UIPageControl(frame: .zero)
        
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
        
        pageControl.numberOfPages = slides.count
        pageControl.currentPage = 0
        pageControl.isHidden = (slides.count == 1)
        
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
        
        addSubview(pageControl)
        pageControl.center(.horizontal, in: self)
        pageControl.pin(.bottom, to: .bottom, of: self)
        
        scrollView.addSubview(stackView)
        stackView.pin([ UIView.HorizontalEdge.leading, UIView.VerticalEdge.top ], to: scrollView)
    }
    
    private func startScrolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimerOnMainThread(withTimeInterval: Self.autoScrollingTimeInterval, repeats: true) { _ in
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
            self.pageControl.currentPage = targetPage
        }
    }
    
    private func stopScrolling() {
        timer?.invalidate()
        timer = nil
    }
}
