// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionUtilitiesKit

public extension SessionProBadge {
    static func trailingImage(
        size: SessionProBadge.Size,
        themeBackgroundColor: ThemeValue
    ) -> SessionCell.TextInfo.TrailingImage {
        return (
            .themedKey(size.cacheKey, themeBackgroundColor: themeBackgroundColor),
            accessibilityLabel: SessionProBadge.accessibilityLabel,
            { SessionProBadge(size: size, themeBackgroundColor: themeBackgroundColor) }
        )
    }
}

//public extension String {
//    enum SessionProBadgePosition {
//        case leading, trailing
//    }
//    
//    @MainActor func addProBadge(
//        at postion: SessionProBadgePosition,
//        font: UIFont,
//        textColor: ThemeValue = .textPrimary,
//        proBadgeSize: SessionProBadge.Size,
//        spacing: String = " ",
//        using dependencies: Dependencies
//    ) -> ThemedAttributedString {
//        let proBadgeImage: UIImage = UIView.image(
//            for: .themedKey(proBadgeSize.cacheKey, themeBackgroundColor: .primary),
//            generator: { SessionProBadge(size: proBadgeSize) }
//        )
//        
//        let base: ThemedAttributedString = ThemedAttributedString()
//        
//        switch postion {
//            case .leading:
//                base.append(
//                    ThemedAttributedString(
//                        image: proBadgeImage,
//                        accessibilityLabel: SessionProBadge.accessibilityLabel,
//                        font: font
//                    )
//                )
//                base.append(ThemedAttributedString(string: spacing))
//                base.append(ThemedAttributedString(string: self, attributes: [.font: font, .themeForegroundColor: textColor]))
//            case .trailing:
//                base.append(ThemedAttributedString(string: self, attributes: [.font: font, .themeForegroundColor: textColor]))
//                base.append(ThemedAttributedString(string: spacing))
//                base.append(
//                    ThemedAttributedString(
//                        image: proBadgeImage,
//                        accessibilityLabel: SessionProBadge.accessibilityLabel,
//                        font: font
//                    )
//                )
//        }
//
//        return base
//    }
//}
