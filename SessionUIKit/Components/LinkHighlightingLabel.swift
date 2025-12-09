// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit

// Requirements:
// • Links should show up properly and be tappable.
// • Text should * not * be selectable.
// • The long press interaction that shows the context menu should still work.

// See https://stackoverflow.com/questions/47983838/how-can-you-change-the-color-of-links-in-a-uilabel
public class LinkHighlightingLabel: UILabel {
    public private(set) var links: [String: NSRange] = [:]
    private(set) var layoutManager = NSLayoutManager()
    public private(set) var textContainer = NSTextContainer(size: CGSize.zero)
    private(set) var textStorage = NSTextStorage() {
        didSet {
            textStorage.addLayoutManager(layoutManager)
        }
    }

    public override var attributedText: NSAttributedString? {
        didSet {
            guard let attributedText: NSAttributedString = attributedText else {
                textStorage = NSTextStorage()
                links = [:]
                return
            }

            textStorage = NSTextStorage(attributedString: attributedText)
            findLinksAndRange(attributeString: attributedText)
        }
    }

    public override var lineBreakMode: NSLineBreakMode {
        didSet {
            textContainer.lineBreakMode = lineBreakMode
        }
    }

    public override var numberOfLines: Int {
        didSet {
            textContainer.maximumNumberOfLines = numberOfLines
        }
    }
    
    public var containsLinks: Bool {
        return !links.isEmpty
    }
    
    // MARK: - Initialization

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    public required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setup()
    }

    private func setup() {
        isUserInteractionEnabled = true
        layoutManager.addTextContainer(textContainer)
        textContainer.lineFragmentPadding = 0
        textContainer.lineBreakMode = lineBreakMode
        textContainer.maximumNumberOfLines  = numberOfLines
        numberOfLines = 0
    }
    
    // MARK: - Layout
    
    public override func layoutSubviews() {
        super.layoutSubviews()
        
        textContainer.size = bounds.size
        
        if preferredMaxLayoutWidth != bounds.width {
            preferredMaxLayoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
    
    public override var intrinsicContentSize: CGSize {
        // Compute layout with the current/expected width
        let width = preferredMaxLayoutWidth > 0 ? preferredMaxLayoutWidth : bounds.width
        let targetWidth = (width > 0) ? width : UIScreen.main.bounds.width

        textContainer.size = CGSize(width: targetWidth, height: .greatestFiniteMagnitude)
        _ = layoutManager.glyphRange(for: textContainer) // forces layout
        let used = layoutManager.usedRect(for: textContainer)

        // Ceil to avoid fractional sizes causing extra lines/clipping
        return CGSize(width: ceil(used.width), height: ceil(used.height))
    }
    
    public override func sizeThatFits(_ size: CGSize) -> CGSize {
        let targetWidth = size.width > 0 ? size.width : UIScreen.main.bounds.width
        textContainer.size = CGSize(width: targetWidth, height: .greatestFiniteMagnitude)
        _ = layoutManager.glyphRange(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        return CGSize(width: min(ceil(used.width), targetWidth), height: ceil(used.height))
    }
    
    // MARK: - Functions
    
    public func urlString(at point: CGPoint) -> String? {
        textContainer.size = bounds.size
        
        let indexOfCharacter = layoutManager.glyphIndex(for: point, in: textContainer)
        for (urlString, range) in links where NSLocationInRange(indexOfCharacter, range) {
            return urlString
        }
        
        return nil
    }

    private func findLinksAndRange(attributeString: NSAttributedString) {
        links = [:]
        let enumerationBlock: (Any?, NSRange, UnsafeMutablePointer<ObjCBool>) -> Void = { [weak self] value, range, isStop in
            guard let strongSelf = self else { return }
            if let value = value {
                let stringValue = "\(value)"
                strongSelf.links[stringValue] = range
            }
        }
        attributeString.enumerateAttribute(.link, in: NSRange(0..<attributeString.length), options: [.longestEffectiveRangeNotRequired], using: enumerationBlock)
        attributeString.enumerateAttribute(.attachment, in: NSRange(0..<attributeString.length), options: [.longestEffectiveRangeNotRequired], using: enumerationBlock)
    }
}
