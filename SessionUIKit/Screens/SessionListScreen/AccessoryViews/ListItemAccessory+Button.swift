// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

public extension SessionListScreenContent.ListItemAccessory {
    static func button(
        _ buttonViewModel: SessionButtonViewModel
    ) -> SessionListScreenContent.ListItemAccessory {
        return SessionListScreenContent.ListItemAccessory(
            padding: -Values.mediumSmallSpacing
        ) {
            SessionButton_SwiftUI(buttonViewModel)
                .frame(maxWidth: .infinity)
        }
    }
}

