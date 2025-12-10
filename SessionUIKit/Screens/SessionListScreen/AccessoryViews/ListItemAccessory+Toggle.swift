// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

public extension SessionListScreenContent.ListItemAccessory {
    static func toggle(
        _ value: Bool,
        oldValue: Bool?,
        accessibility: Accessibility = Accessibility(identifier: "Switch")
    ) -> SessionListScreenContent.ListItemAccessory {
        return SessionListScreenContent.ListItemAccessory {
            AnimatedToggle(
                value: value,
                oldValue: oldValue,
                accessibility: accessibility
            )
        }
    }
}
