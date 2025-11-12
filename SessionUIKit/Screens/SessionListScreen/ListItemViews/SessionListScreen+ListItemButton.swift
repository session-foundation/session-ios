// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import DifferenceKit

// MARK: - ListItemButton

struct ListItemButton: View {
    let title: String
    let enabled: Bool

    var body: some View {
        Text(title)
            .font(.Body.largeRegular)
            .foregroundColor(themeColor: .sessionButton_primaryFilledText)
            .framing(
                maxWidth: .infinity,
                height: 50,
                alignment: .center
            )
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(themeColor: enabled ? .sessionButton_primaryFilledBackground : .disabled)
            )
    }
}

