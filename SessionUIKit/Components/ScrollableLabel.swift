// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import UIKit

class ScrollableLabel: UIView {
    private var oldSize: CGSize = .zero
    private var layoutLoopCounter: Int = 0
    
    var canScroll: Bool = false {
        didSet {
            guard canScroll != oldValue else { return }
            
            updateContentSizeIfNeeded()
        }
    }
    
    var font: UIFont {
        get { label.font }
        set { label.font = newValue }
    }
    
    var text: String? {
        get { label.text }
        set {
            guard label.text != newValue else { return }
            
            label.text = newValue
            updateContentSizeIfNeeded()
        }
    }
    
    var attributedText: NSAttributedString? {
        get { label.attributedText }
        set {
            guard label.attributedText != newValue else { return }
            
            label.attributedText = newValue
            updateContentSizeIfNeeded()
        }
    }
    
    var themeTextColor: ThemeValue? {
        get { label.themeTextColor }
        set { label.themeTextColor = newValue }
    }
    
    var textAlignment: NSTextAlignment {
        get { label.textAlignment }
        set { label.textAlignment = newValue }
    }
    
    var lineBreakMode: NSLineBreakMode {
        get { label.lineBreakMode }
        set { label.lineBreakMode = newValue }
    }
    
    var numberOfLines: Int {
        get { label.numberOfLines }
        set { label.numberOfLines = newValue }
    }
    
    var maxNumberOfLinesWhenScrolling: Int = 5 {
        didSet {
            guard maxNumberOfLinesWhenScrolling != oldValue else { return }
            
            updateContentSizeIfNeeded()
        }
    }
    
    // MARK: - Initialization
    
    init() {
        super.init(frame: .zero)
        
        setupViews()
        setupConstraints()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - UI Components
    
    private lazy var labelHeightAnchor: NSLayoutConstraint = label.set(.height, to: .height, of: scrollView).setting(isActive: false)
    private lazy var scrollViewHeightAnchor: NSLayoutConstraint = scrollView.set(.height, to: 0).setting(isActive: false)
    
    private let scrollView: UIScrollView = UIScrollView()
    private let label: UILabel = UILabel()
    
    // MARK: - Layout
    
    private func setupViews() {
        addSubview(scrollView)
        
        scrollView.addSubview(label)
    }
    
    private func setupConstraints() {
        scrollView.pin(to: self)
        
        label.setContentHugging(.vertical, to: .required)
        label.pin(to: scrollView)
        label.set(.width, to: .width, of: scrollView)
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        
        guard frame.size != oldSize else {
            layoutLoopCounter = 0
            return
        }
        
        updateContentSizeIfNeeded()
    }
    
    private func updateContentSizeIfNeeded() {
        // Ensure we don't get stuck in an infinite layout loop somehow
        guard layoutLoopCounter < 5 else { return }
        
        // Update the contentSize of the scrollView to match the size of the label
        scrollView.contentSize = label.sizeThatFits(
            CGSize(width: scrollView.bounds.width, height: CGFloat.greatestFiniteMagnitude)
        )
        
        // If scrolling is enabled and the maximum height we want to show is smaller than the scrollable height
        // then we need to fix the height of the scroll view to our desired maximum, other
        let maxCalculatedHeight: CGFloat = (label.font.lineHeight * CGFloat(maxNumberOfLinesWhenScrolling))
        
        switch (canScroll, maxCalculatedHeight <= scrollView.contentSize.height) {
            case (false, _), (true, false):
                scrollViewHeightAnchor.isActive = false
                labelHeightAnchor.isActive = true
                
            case (true, true):
                labelHeightAnchor.isActive = false
                scrollViewHeightAnchor.constant = maxCalculatedHeight
                scrollViewHeightAnchor.isActive = true
        }
        
        oldSize = frame.size
        
        // The view should have the same height as the scrollView, if it doesn't then we might need to relayout
        // again to ensure the frame size is correct
        guard
            scrollView.frame.size.height < CGFloat.leastNonzeroMagnitude ||
            abs(frame.size.height - scrollView.frame.size.height) > CGFloat.leastNonzeroMagnitude
        else { return }
        
        layoutLoopCounter += 1
        setNeedsLayout()
        layoutIfNeeded()
    }
}
