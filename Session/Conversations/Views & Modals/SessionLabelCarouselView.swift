// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionUtilitiesKit

final class SessionLabelCarouselView: UIView, UIScrollViewDelegate {
    public static let font: UIFont = .systemFont(ofSize: Values.miniFontSize)
    private static let autoScrollingTimeInterval: TimeInterval = 10
    private static let chevronInset: CGFloat = 8  /// 5pt chevron + 3pt padding
    private static let pageControlTopGap: CGFloat = 3
    private static let pageControlHeight: CGFloat = 8
    
    private let dependencies: Dependencies
    public private(set) var originalLabelInfos: [LabelInfo] = []
    public private(set) var labelInfos: [LabelInfo] = []
    private var labelSize: CGSize = .zero
    private var shouldAutoScroll: Bool = false
    private var timer: Timer?
    
    private lazy var contentWidth = stackView.set(.width, to: 0)
    
    override var intrinsicContentSize: CGSize {
        guard labelSize != .zero else { return super.intrinsicContentSize }
        
        let naturalHeight: CGFloat = (stackView.arrangedSubviews.map {
            $0.systemLayoutSizeFitting(
                CGSize(width: labelSize.width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height
        }.max() ?? labelSize.height)
        
        /// When scrolling is active, add room for the page control below the content
        let pageControlTotalHeight: CGFloat = (shouldScroll ?
            (SessionLabelCarouselView.pageControlTopGap + SessionLabelCarouselView.pageControlHeight) :
            0
        )
        
        return CGSize(width: labelSize.width, height: naturalHeight + pageControlTotalHeight)
    }
    
    private var shouldScroll: Bool = false {
        didSet {
            arrowLeft.isHidden = !shouldScroll
            arrowRight.isHidden = !shouldScroll
            pageControl.isHidden = !shouldScroll
            scrollView.isScrollEnabled = shouldScroll
            invalidateIntrinsicContentSize() /// Height changes with/without page control
        }
    }
    
    public struct LabelInfo {
        let attributedText: ThemedAttributedString
        let accessibility: Accessibility?
        let type: LabelType
    }
    
    // MARK: - Types
    
    public enum LabelType {
        case notificationSettings
        case userCount
        case disappearingMessageSetting
    }
    
    public var currentLabelType: LabelType? {
        let index = pageControl.currentPage + (shouldScroll ? 1 : 0)
        return self.labelInfos[safe: index]?.type
    }
    
    // MARK: - UI Components
    
    public lazy var scrollView: UIScrollView = {
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
        result.alignment = .center
        
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
    
    init(labelInfos: [LabelInfo] = [], labelSize: CGSize = .zero, shouldAutoScroll: Bool = false, using dependencies: Dependencies) {
        self.dependencies = dependencies
        
        super.init(frame: .zero)
        
        setUpViewHierarchy()
        self.update(with: labelInfos, labelSize: labelSize, shouldAutoScroll: shouldAutoScroll)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Content
    
    public func update(with labelInfos: [LabelInfo], labelSize: CGSize = .zero, shouldAutoScroll: Bool = false) {
        self.originalLabelInfos = labelInfos
        self.labelInfos = labelInfos
        self.labelSize = labelSize
        self.shouldAutoScroll = shouldAutoScroll
        self.shouldScroll = labelInfos.count > 1
        
        if self.shouldScroll {
            let first: LabelInfo = labelInfos.first!
            let last: LabelInfo = labelInfos.last!
            self.labelInfos.append(first)
            self.labelInfos.insert(last, at: 0)
        }
        
        pageControl.numberOfPages = labelInfos.count
        pageControl.currentPage = 0
        
        let contentSize = CGSize(width: labelSize.width * CGFloat(self.labelInfos.count), height: labelSize.height)
        scrollView.contentSize = contentSize
        contentWidth.constant = contentSize.width
        self.scrollView.setContentOffset(
            CGPoint(
                x: Int(self.labelSize.width) * (self.shouldScroll ? 1 : 0),
                y: 0
            ),
            animated: false
        )
        
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        
        self.labelInfos.forEach {
            let wrapper: UIView = UIView()
            wrapper.set(.width, to: labelSize.width)
            
            let label: UILabel = UILabel()
            label.font = SessionLabelCarouselView.font
            label.themeTextColor = .textPrimary
            label.textAlignment = .center
            label.lineBreakMode = .byWordWrapping
            label.numberOfLines = 2
            label.themeAttributedText = $0.attributedText
            label.accessibilityIdentifier = $0.accessibility?.identifier
            label.accessibilityLabel = $0.accessibility?.label
            label.isAccessibilityElement = true
            wrapper.addSubview(label)
            
            /// Inset horizontally when scrolling so text doesn't sit behind the chevrons
            let horizontalInset: CGFloat = (shouldScroll ? SessionLabelCarouselView.chevronInset : 0)
            label.pin(.top, to: .top, of: wrapper)
            label.pin(.bottom, to: .bottom, of: wrapper)
            label.pin(.leading, to: .leading, of: wrapper, withInset: horizontalInset)
            label.pin(.trailing, to: .trailing, of: wrapper, withInset: -horizontalInset)
            
            stackView.addArrangedSubview(wrapper)
        }
        
        if self.shouldAutoScroll {
            startScrolling()
        }
        
        invalidateIntrinsicContentSize()
    }
    
    private func setUpViewHierarchy() {
        addSubview(scrollView)
        scrollView.pin(.top, to: .top, of: self)
        scrollView.pin(.leading, to: .leading, of: self)
        scrollView.pin(.trailing, to: .trailing, of: self)
        
        addSubview(arrowLeft)
        arrowLeft.pin(.left, to: .left, of: self)
        arrowLeft.center(.vertical, in: scrollView)
        
        addSubview(arrowRight)
        arrowRight.pin(.right, to: .right, of: self)
        arrowRight.center(.vertical, in: scrollView)
        
        addSubview(pageControl)
        pageControl.center(.horizontal, in: self)
        pageControl.pin(.top, to: .bottom, of: scrollView)
        pageControl.pin(
            .bottom,
            to: .bottom,
            of: self,
            withInset: {
                if #available(iOS 26.0, *) {
                    return 0
                }
                
                return -1
            }()
        )
        
        scrollView.addSubview(stackView)
        scrollView.set(.height, to: .height, of: stackView)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        
        // FIXME: Update the layout DSL to support these anchors
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor)
        ])
    }
    
    // MARK: - Interaction
    
    private func startScrolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimerOnMainThread(withTimeInterval: Self.autoScrollingTimeInterval, repeats: true) { _ in
            guard self.labelInfos.count != 0 else { return }
            let targetPage = (self.pageControl.currentPage + 1) % self.labelInfos.count
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
            guard labelSize.width > 0 else { return 0 }
            let maybeCurrentPageIndex: Int = Int(round(scrollView.contentOffset.x/labelSize.width))
            if self.shouldScroll {
                if maybeCurrentPageIndex == 0 {
                    return pageControl.numberOfPages - 1
                }
                if maybeCurrentPageIndex == self.labelInfos.count - 1 {
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
            let realLastIndex: Int = self.labelInfos.count - 2
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
