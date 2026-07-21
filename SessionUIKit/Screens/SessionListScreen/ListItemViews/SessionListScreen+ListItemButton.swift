// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import DifferenceKit

// MARK: - ListItemButton

struct ListItemButton: View {
    let title: String
    let enabled: Bool
    
    @State private var isPressed: Bool = false

    var body: some View {
        let color: ThemeValue = switch (enabled, isPressed) {
            case (false, _): .disabled
            case (true, false): .sessionButton_primaryFilledBackground
            case (true, true):
                .value(.sessionButton_primaryFilledBackground, alpha: 0.5)
        }
        
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
                    .fill(themeColor: color)
            )
            .onLongPressGesture(minimumDuration: 0, pressing: { pressing in
                isPressed = pressing
            }, perform: {})
    }
}

#if DEBUG
#Preview {
    ListItemButton(title: "Test", enabled: true)
        .padding()
}
#endif
