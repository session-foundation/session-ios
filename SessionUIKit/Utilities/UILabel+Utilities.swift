// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit

public extension UILabel {
    /// Appends a rendered snapshot of `view` as an inline image attachment.
    func attachTrailing(cacheKey: CachedImageKey?, viewGenerator: (() -> UIView)?, spacing: String = " ") {
        guard let cacheKey, let viewGenerator else { return }

        let base = ThemedAttributedString()
        if let existing = attributedText, existing.length > 0 {
            base.append(existing)
        } else if let t = text {
            base.append(NSAttributedString(string: t, attributes: [.font: font as Any, .foregroundColor: textColor as Any]))
        }

        base.append(NSAttributedString(string: spacing))
        base.append(ThemedAttributedString(
            imageAttachmentGenerator: { UIView.image(for: cacheKey, generator: viewGenerator) },
            referenceFont: font
        ))

        themeAttributedText = base
        numberOfLines = 0
        lineBreakMode = .byWordWrapping
    }
    
    func isPointOnAttachment(_ point: CGPoint, hitPadding: CGFloat = 0) -> Bool {
        guard let attributed = attributedText, attributed.length > 0 else { return false }

        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = numberOfLines
        textContainer.lineBreakMode = lineBreakMode

        let textStorage = NSTextStorage(attributedString: attributed)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        layoutManager.ensureLayout(for: textContainer)

        let glyphRange = layoutManager.glyphRange(for: textContainer)
        if glyphRange.length == 0 { return false }

        // Find which line fragment contains the point
        var lineOrigin = CGPoint.zero
        var lineRect = CGRect.zero
        var foundLine = false
        
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { rect, usedRect, _, _, stop in
            if rect.contains(CGPoint(x: 0, y: point.y)) {
                lineRect = usedRect
                lineOrigin = rect.origin
                foundLine = true
                stop.pointee = true
            }
        }
        
        guard foundLine else { return false }

        // Calculate horizontal offset for this specific line
        var xOffset: CGFloat = 0
        switch textAlignment {
            case .center:
                xOffset = lineOrigin.x + (lineRect.width < bounds.width ? (bounds.width - lineRect.width) / 2.0 : 0)
            case .right:
                xOffset = lineOrigin.x + (lineRect.width < bounds.width ? bounds.width - lineRect.width : 0)
            case .natural where effectiveUserInterfaceLayoutDirection == .rightToLeft:
                xOffset = lineOrigin.x + (lineRect.width < bounds.width ? bounds.width - lineRect.width : 0)
            default:
                xOffset = lineOrigin.x
        }

        let pt = CGPoint(x: point.x - xOffset, y: point.y)
        
        // Check if point is within text bounds with padding
        let textBounds = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        if !textBounds.insetBy(dx: -hitPadding, dy: -hitPadding).contains(pt) { return false }

        let idx = layoutManager.characterIndex(for: pt, in: textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
        guard idx < attributed.length else { return false }

        var range = NSRange(location: 0, length: 0)
        guard attributed.attribute(.attachment, at: idx, effectiveRange: &range) is NSTextAttachment else {
            return false
        }

        let attGlyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let attRect = layoutManager.boundingRect(forGlyphRange: attGlyphRange, in: textContainer)
        return attRect.insetBy(dx: -hitPadding, dy: -hitPadding).contains(pt)
    }
}
