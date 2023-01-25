// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

final class SessionCarouselView: UIView, UIScrollViewDelegate {
    private let slices: [UIView]
    private let sliceSize: CGSize
    
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
            width: self.sliceSize.width * CGFloat(self.slices.count),
            height: self.sliceSize.height
        )
        
        return result
    }()
    
    private lazy var pageControl: UIPageControl = {
        let result: UIPageControl = UIPageControl()
        result.numberOfPages = self.slices.count
        
        return result
    }()
    
    // MARK: - Lifecycle
    init(slices: [UIView], sliceSize: CGSize) {
        self.slices = slices
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
        let stackView: UIStackView = UIStackView(arrangedSubviews: self.slices)
        stackView.axis = .horizontal
        stackView.set(.width, to: self.sliceSize.width * CGFloat(self.slices.count))
        stackView.set(.height, to: self.sliceSize.height)
        
        addSubview(self.scrollView)
        scrollView.pin(to: self)
        scrollView.set(.width, to: self.sliceSize.width)
        scrollView.set(.height, to: self.sliceSize.height)
        scrollView.addSubview(stackView)
        
        addSubview(self.pageControl)
        self.pageControl.center(.horizontal, in: self)
        self.pageControl.pin(.bottom, to: .bottom, of: self)
    }
    
    // MARK: - UIScrollViewDelegate
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        
    }
}
