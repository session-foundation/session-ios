// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit

public class ExpandableLabel: UIView {
    private var isExpanded: Bool = false
    
    private var oldSize: CGSize = .zero
    private var layoutLoopCounter: Int = 0
    
    public var font: UIFont {
        get { scrollableLabel.font }
        set { scrollableLabel.font = newValue }
    }
    
    public var text: String? {
        get { scrollableLabel.text }
        set { scrollableLabel.text = newValue }
    }
    
    public var attributedText: NSAttributedString? {
        get { scrollableLabel.attributedText }
        set { scrollableLabel.attributedText = newValue }
    }
    
    public var themeTextColor: ThemeValue? {
        get { scrollableLabel.themeTextColor }
        set { scrollableLabel.themeTextColor = newValue }
    }
    
    public var textAlignment: NSTextAlignment {
        get { scrollableLabel.textAlignment }
        set { scrollableLabel.textAlignment = newValue }
    }
    
    public var lineBreakMode: NSLineBreakMode {
        get { scrollableLabel.lineBreakMode }
        set { scrollableLabel.lineBreakMode = newValue }
    }
    
    public var numberOfLines: Int {
        get { scrollableLabel.numberOfLines }
        set { scrollableLabel.numberOfLines = newValue }
    }
    
    public var maxNumberOfLinesWhenScrolling: Int {
        get { scrollableLabel.maxNumberOfLinesWhenScrolling }
        set { scrollableLabel.maxNumberOfLinesWhenScrolling = newValue }
    }
    
    public var maxNumberOfLinesNeedsNoCollapse: Int = 3
    public var numberOfLinesAfterCollapse: Int = 2
    
    public var viewMoreButtonTitle: String = "viewMore".localized()
    public var viewLessButtonTitle: String = "viewLess".localized()
    
    
    // MARK: - Initialization
    
    public init() {
        super.init(frame: .zero)
        
        setupViewsAndConstraints()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - UI Components
    
    private let scrollableLabel: ScrollableLabel = ScrollableLabel()
    private let buttonLabel: UILabel = UILabel()
    
    // MARK: - Layout
    
    private func setupViewsAndConstraints() {
        buttonLabel.text = isExpanded ? viewLessButtonTitle : viewMoreButtonTitle
        buttonLabel.font = .boldSystemFont(ofSize: Values.smallFontSize)
        buttonLabel.themeTextColor = .primary
        
        let stackView: UIStackView = UIStackView(arrangedSubviews: [scrollableLabel, buttonLabel])
        stackView.axis = .vertical
        stackView.spacing = Values.smallSpacing
        
        addSubview(stackView)
        stackView.pin(to: self)
    }
    
    public override func layoutSubviews() {
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
        
        if scrollableLabel.frame.height < font.lineHeight * CGFloat(maxNumberOfLinesNeedsNoCollapse) {
            buttonLabel.isHidden = true
            scrollableLabel.scrollMode = .never
            scrollableLabel.numberOfLines = 0
        } else {
            buttonLabel.isHidden = false
            if isExpanded {
                buttonLabel.text = viewLessButtonTitle
                scrollableLabel.scrollMode = .automatic
                scrollableLabel.maxNumberOfLinesWhenScrolling = maxNumberOfLinesWhenScrolling
            } else {
                buttonLabel.text = viewMoreButtonTitle
                scrollableLabel.scrollMode = .never
                scrollableLabel.numberOfLines = numberOfLinesAfterCollapse
                scrollableLabel.lineBreakMode = .byTruncatingTail
            }
        }
        
        layoutLoopCounter += 1
        setNeedsLayout()
        layoutIfNeeded()
    }
}
