// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionUtilitiesKit

public extension SessionProBadge.Size{
    // stringlint:ignore_contents
    var cacheKey: String {
        switch self {
            case .mini: return "SessionProBadge.Mini"
            case .small: return "SessionProBadge.Small"
            case .medium: return "SessionProBadge.Medium"
            case .large: return "SessionProBadge.Large"
        }
    }
}

public extension SessionProBadge {
    func toImage(using dependencies: Dependencies) -> UIImage {
        let themePrimaryColor = dependencies.mutate(cache: .libSession) { libSession -> Theme.PrimaryColor? in libSession.get(.themePrimaryColor)}
        let cacheKey: String = self.size.cacheKey + ".\(themePrimaryColor.defaulting(to: .defaultPrimaryColor))" // stringlint:ignore
        
        if let cachedImage = dependencies[cache: .generalUI].get(for: cacheKey) {
            return cachedImage
        }
        
        let renderedImage = self.toImage(isOpaque: self.isOpaque, scale: UIScreen.main.scale)
        dependencies.mutate(cache: .generalUI) { $0.cache(renderedImage, for: cacheKey) }
        return renderedImage
    }
}

public extension String {
    enum SessionProBadgePosition {
        case leading, trailing
    }
    
    func addProBadge(
        at postion: SessionProBadgePosition,
        font: UIFont,
        textColor: ThemeValue = .textPrimary,
        proBadgeSize: SessionProBadge.Size,
        spacing: String = " ",
        using dependencies: Dependencies
    ) -> NSMutableAttributedString {
        let image: UIImage = SessionProBadge(size: proBadgeSize).toImage(using: dependencies)
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
