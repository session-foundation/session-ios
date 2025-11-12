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
                            SessionProBadge(size: proBadgeSize)
                                .toImage(
                                    cacheKey: proBadgeSize.cacheKey,
                                    using: dependencies
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
                            SessionProBadge(size: proBadgeSize)
                                .toImage(
                                    cacheKey: proBadgeSize.cacheKey,
                                    using: dependencies
                                )
                        },
                        referenceFont: font
                    )
                )
        }

        return base
    }
}
