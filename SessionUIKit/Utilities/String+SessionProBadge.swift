// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit

public extension String {
    enum SessionProBadgePosition {
        case leading, trailing
    }
    
    func addProBadge(
        at postion: SessionProBadgePosition,
        font: UIFont,
        textColor: ThemeValue = .textPrimary,
        proBadgeSize: SessionProBadge.Size,
        spacing: String = " "
    ) -> NSMutableAttributedString {
        let image: UIImage = SessionProBadge(size: proBadgeSize).toImage()
        let base = NSMutableAttributedString()
        let attachment = NSTextAttachment()
        attachment.image = image
        
        // Vertical alignment tweak to align to baseline
        let cap = font.capHeight
        let dy = (cap - image.size.height) / 2
        attachment.bounds = CGRect(x: 0, y: dy, width: image.size.width, height: image.size.height)
        
        switch postion {
            case .leading:
                base.append(NSAttributedString(attachment: attachment))
                base.append(NSAttributedString(string: spacing))
                base.append(NSAttributedString(string: self, attributes: [.font: font, .themeForegroundColor: textColor]))
            case .trailing:
                base.append(NSAttributedString(string: self, attributes: [.font: font, .themeForegroundColor: textColor]))
                base.append(NSAttributedString(string: spacing))
                base.append(NSAttributedString(attachment: attachment))
        }

        return base
    }
}
