// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

public extension SessionListScreenContent.ListItemAccessory {
    static func loadingIndicator(
        size: IconSize = .medium,
        customTint: ThemeValue = .textPrimary,
        accessibility: Accessibility? = nil
    ) -> SessionListScreenContent.ListItemAccessory {
        return SessionListScreenContent.ListItemAccessory {
            ProgressView()
                .tint(themeColor: customTint)
                .controlSize(.regular)
                .scaleEffect(size.size / 20)
                .frame(width: size.size, height: size.size)
                .accessibility(accessibility)
        }
    }
}
