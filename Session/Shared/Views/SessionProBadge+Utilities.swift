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
