// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit

final class SessionLabelCarouselView: UIView, UIScrollViewDelegate {
    private static let autoScrollingTimeInterval: TimeInterval = 10
    private var labelStrings: [NSAttributedString] = []
    private var labelTypes: [LabelType] = [.empty]
    private var labelSize: CGSize = .zero
    private var shouldAutoScroll: Bool = false
    private var timer: Timer?
    
    private lazy var contentWidth = stackView.set(.width, to: 0)
    private lazy var contentHeight = stackView.set(.height, to: 0)
    
    private var shouldScroll: Bool = false {
        didSet {
            arrowLeft.isHidden = !shouldScroll
            arrowRight.isHidden = !shouldScroll
            pageControl.isHidden = !shouldScroll
        }
    }
    
    // MARK: - Types
    
    public enum LabelType {
        case notificationSettings
        case userCount
        case disappearingMessageSetting
        case empty
    }
    
    public var currentLabelType: LabelType {
        return self.labelTypes[pageControl.currentPage]
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
        result.currentPage = 0
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
    
    init(labelStrings: [NSAttributedString] = [], labelTypes: [LabelType] = [.empty], labelSize: CGSize = .zero, shouldAutoScroll: Bool = false) {
        super.init(frame: .zero)
        setUpViewHierarchy()
        self.update(with: labelStrings, labelTypes: labelTypes, labelSize: labelSize, shouldAutoScroll: shouldAutoScroll)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Content
    
    public func update(with labelStrings: [NSAttributedString], labelTypes: [LabelType], labelSize: CGSize = .zero, shouldAutoScroll: Bool = false) {
        self.labelStrings = labelStrings
        self.labelTypes = labelTypes.isEmpty ? [.empty] : labelTypes
        self.labelSize = labelSize
        self.shouldAutoScroll = shouldAutoScroll
        self.shouldScroll = labelStrings.count > 1
        
        if self.shouldScroll {
            let first: NSAttributedString = labelStrings.first!
            let last: NSAttributedString = labelStrings.last!
            self.labelStrings.append(first)
            self.labelStrings.insert(last, at: 0)
        }
        
        pageControl.numberOfPages = labelStrings.count
        pageControl.currentPage = 0
        
        let contentSize = CGSize(width: labelSize.width * CGFloat(self.labelStrings.count), height: labelSize.height)
        scrollView.contentSize = contentSize
        contentWidth.constant = contentSize.width
        contentHeight.constant = contentSize.height
        self.scrollView.setContentOffset(
            CGPoint(
                x: Int(self.labelSize.width) * (self.shouldScroll ? 1 : 0),
                y: 0
            ),
            animated: false
        )
        
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        
        self.labelStrings.forEach {
            let wrapper: UIView = UIView()
            wrapper.set(.width, to: labelSize.width)
            wrapper.set(.height, to: labelSize.height)
            let label: UILabel = UILabel()
            label.font = .systemFont(ofSize: Values.miniFontSize)
            label.themeTextColor = .textPrimary
            label.lineBreakMode = .byTruncatingTail
            label.attributedText = $0
            wrapper.addSubview(label)
            label.center(in: wrapper)
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
        pageControl.pin(.bottom, to: .bottom, of: self)
        
        scrollView.addSubview(stackView)
    }
    
    private func startScrolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimerOnMainThread(withTimeInterval: Self.autoScrollingTimeInterval, repeats: true) { _ in
            guard self.labelStrings.count != 0 else { return }
            let targetPage = (self.pageControl.currentPage + 1) % self.labelStrings.count
            self.scrollView.scrollRectToVisible(
                CGRect(
                    origin: CGPoint(
                        x: Int(self.labelSize.width) * targetPage,
                        y: 0
                    ),
                    size: self.labelSize
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
        let pageIndex: Int = {
            let maybeCurrentPageIndex: Int = Int(round(scrollView.contentOffset.x/labelSize.width))
            if self.shouldScroll {
                if maybeCurrentPageIndex == 0 {
                    return pageControl.numberOfPages - 1
                }
                if maybeCurrentPageIndex == self.labelStrings.count - 1 {
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
                    x: Int(self.labelSize.width) * 1,
                    y: 0
                ),
                animated: false
            )
        }
        
        if pageControl.currentPage == pageControl.numberOfPages - 1 {
            let realLastIndex: Int = self.labelStrings.count - 2
            scrollView.setContentOffset(
                CGPoint(
                    x: Int(self.labelSize.width) * realLastIndex,
                    y: 0
                ),
                animated: false
            )
        }
    }
}
