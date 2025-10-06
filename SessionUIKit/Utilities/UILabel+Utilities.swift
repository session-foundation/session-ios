// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit

public extension UILabel {
    /// Appends a rendered snapshot of `view` as an inline image attachment.
    func attachTrailing(_ imageGenerator: (() -> UIImage?)?, spacing: String = " ") {
        guard let imageGenerator else { return }

        let base = ThemedAttributedString()
        if let existing = attributedText, existing.length > 0 {
            base.append(existing)
        } else if let t = text {
            base.append(NSAttributedString(string: t, attributes: [.font: font as Any, .foregroundColor: textColor as Any]))
        }

        base.append(NSAttributedString(string: spacing))
        base.append(ThemedAttributedString(imageAttachmentGenerator: imageGenerator))

        themeAttributedText = base
        numberOfLines = 0
        lineBreakMode = .byWordWrapping
    }
    
    /// Returns true if `point` (in this label's coordinate space) hits a drawn NSTextAttachment at the end of the string.
    /// Works with multi-line labels, alignment, and truncation.
    func isPointOnTrailingAttachment(_ point: CGPoint, hitPadding: CGFloat = 0) -> Bool {
        guard let attributed = attributedText, attributed.length > 0 else { return false }

        // Reuse the general function but also ensure the attachment range ends at string end.
        // We re-run the minimal parts to get the effectiveRange.
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
        let textBounds = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)

        var textOrigin = CGPoint.zero
        switch textAlignment {
        case .center: textOrigin.x = (bounds.width - textBounds.width) / 2.0
        case .right:  textOrigin.x = bounds.width - textBounds.width
        case .natural where effectiveUserInterfaceLayoutDirection == .rightToLeft:
            textOrigin.x = bounds.width - textBounds.width
        default: break
        }

        let pt = CGPoint(x: point.x - textOrigin.x, y: point.y - textOrigin.y)
        if !textBounds.insetBy(dx: -hitPadding, dy: -hitPadding).contains(pt) { return false }

        let idx = layoutManager.characterIndex(for: pt, in: textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
        guard idx < attributed.length else { return false }

        var range = NSRange(location: 0, length: 0)
        guard attributed.attribute(.attachment, at: idx, effectiveRange: &range) is NSTextAttachment,
              NSMaxRange(range) == attributed.length else {
            return false
        }

        let attGlyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let attRect = layoutManager.boundingRect(forGlyphRange: attGlyphRange, in: textContainer)
        return attRect.insetBy(dx: -hitPadding, dy: -hitPadding).contains(pt)
    }
}
