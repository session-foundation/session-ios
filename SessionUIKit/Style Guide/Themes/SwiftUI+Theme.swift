// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

public extension View {
    func themeForegroundColor(themeColor: ThemeValue) -> some View {
        return self.foregroundColor(
            Color(.white)
        )
    }
}
