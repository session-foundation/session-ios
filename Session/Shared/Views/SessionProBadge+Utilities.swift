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
    fileprivate static let accessibilityLabel: String = Constants.app_pro
    
    static func trailingImage(
        size: SessionProBadge.Size,
        themeBackgroundColor: ThemeValue
    ) -> SessionCell.TextInfo.TrailingImage {
        return (
            .themedKey(size.cacheKey, themeBackgroundColor: themeBackgroundColor),
            accessibilityLabel: SessionProBadge.accessibilityLabel,
            { SessionProBadge(size: size) }
        )
    }
    
    func toImage(using dependencies: Dependencies) -> UIImage {
        let themePrimaryColor: Theme.PrimaryColor = dependencies
            .mutate(cache: .libSession) { $0.get(.themePrimaryColor) }
            .defaulting(to: .defaultPrimaryColor)
        let cacheKey: String = "\(self.size.cacheKey).\(themePrimaryColor)" // stringlint:ignore
        
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
    ) -> ThemedAttributedString {
        let base = ThemedAttributedString()
        switch postion {
            case .leading:
                base.append(
                    ThemedAttributedString(
                        imageAttachmentGenerator: {
                            (
                                UIView.image(
                                    for: .themedKey(proBadgeSize.cacheKey, themeBackgroundColor: .primary),
                                    generator: { SessionProBadge(size: proBadgeSize) }
                                ),
                                SessionProBadge.accessibilityLabel
                            )
                        },
                        referenceFont: font
                    )
                )
                base.append(ThemedAttributedString(string: spacing))
                base.append(ThemedAttributedString(string: self, attributes: [.font: font, .themeForegroundColor: textColor]))
            case .trailing:
                base.append(ThemedAttributedString(string: self, attributes: [.font: font, .themeForegroundColor: textColor]))
                base.append(ThemedAttributedString(string: spacing))
                base.append(
                    ThemedAttributedString(
                        imageAttachmentGenerator: {
                            (
                                UIView.image(
                                    for: .themedKey(proBadgeSize.cacheKey, themeBackgroundColor: .primary),
                                    generator: { SessionProBadge(size: proBadgeSize) }
                                ),
                                SessionProBadge.accessibilityLabel
                            )
                        },
                        referenceFont: font
                    )
                )
        }

        return base
    }
}
