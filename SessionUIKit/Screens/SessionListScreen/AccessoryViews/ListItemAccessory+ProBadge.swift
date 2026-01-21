// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

public extension SessionListScreenContent.ListItemAccessory {
    static func proBadge(
        size: SessionProBadge.Size,
        themeBackgroundColor: ThemeValue,
        backgroundSize: IconSize = .medium
    ) -> SessionListScreenContent.ListItemAccessory {
        return SessionListScreenContent.ListItemAccessory(
            padding: Values.smallSpacing
        ) {
            ZStack {
                SessionProBadge_SwiftUI(
                    size: size,
                    themeBackgroundColor: themeBackgroundColor
                )
            }
            .frame(
                width: backgroundSize.size,
                height: backgroundSize.size
            )
        }
    }
}
