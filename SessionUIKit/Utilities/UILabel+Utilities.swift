// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit

public extension UILabel {
    /// Appends a rendered snapshot of `view` as an inline image attachment.
    func attachTrailing(view: UIView?, spacing: String = " ") {
        guard let view = view, view.bounds.size != .zero else { return }

        let base = NSMutableAttributedString()
        if let existing = attributedText, existing.length > 0 {
            base.append(existing)
        } else if let t = text {
            base.append(NSAttributedString(string: t, attributes: [.font: font as Any, .foregroundColor: textColor as Any]))
        }

        let img = view.toImage(isOpaque: view.isOpaque, scale: UIScreen.main.scale)
        let attachment = NSTextAttachment()
        attachment.image = img

        // Vertical alignment tweak to align to baseline
        let cap = font?.capHeight ?? 0
        let dy = (cap - view.bounds.height) / 2
        attachment.bounds = CGRect(x: 0, y: dy, width: view.bounds.width, height: view.bounds.height)

        base.append(NSAttributedString(string: spacing))
        base.append(NSAttributedString(attachment: attachment))

        attributedText = base
        numberOfLines = 0
        lineBreakMode = .byWordWrapping
    }
}
