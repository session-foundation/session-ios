// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import DifferenceKit

// MARK: - ListItemButton

struct ListItemButton: View {
    let title: String
    let enabled: Bool
    let onTapAction: () -> Void
    
    @GestureState private var isPressed = false

    var body: some View {
        Button {
            onTapAction()
        } label: {
            Text(title)
        }
        .buttonStyle(ListItemButtonStyle(enabled: enabled))
        .disabled(!enabled)
    }
}

struct ListItemButtonStyle: ButtonStyle {
    let enabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        let color: ThemeValue = switch (enabled, configuration.isPressed) {
            case (false, _): .disabled
            case (true, false): .sessionButton_primaryFilledBackground
            case (true, true): .value(.sessionButton_primaryFilledBackground, alpha: 0.5)
        }

        configuration.label
            .font(.Body.largeRegular)
            .foregroundColor(themeColor: .sessionButton_primaryFilledText)
            .framing(maxWidth: .infinity, height: 50, alignment: .center)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(themeColor: color)
            )
    }
}

#if DEBUG
#Preview {
    ListItemButton(title: "Test", enabled: true, onTapAction: {})
        .padding()
}
#endif
