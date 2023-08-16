// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

public extension View {
    func foregroundColor(themeColor: ThemeValue) -> some View {
        return self.foregroundColor(
            ThemeManager.currentTheme.colorSwiftUI(for: themeColor)
        )
    }
    
    func backgroundColor(themeColor: ThemeValue) -> some View {
        return self.background(
            ThemeManager.currentTheme.colorSwiftUI(for: themeColor)
        )
    }
}

public extension Shape {
    func fill(themeColor: ThemeValue) -> some View {
        return self.fill(
            ThemeManager.currentTheme.colorSwiftUI(for: themeColor) ?? Color.primary
        )
    }
    
    func stroke(themeColor: ThemeValue) -> some View {
        return self.stroke(
            ThemeManager.currentTheme.colorSwiftUI(for: themeColor) ?? Color.primary
        )
    }
}
