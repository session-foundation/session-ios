// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

public extension View {
    func foregroundColor(themeColor: ThemeValue) -> some View {
        return self.foregroundColor(ThemeManager.color(for: themeColor))
    }
    
    func backgroundColor(themeColor: ThemeValue) -> some View {
        let targetColor: Color? = ThemeManager.color(for: themeColor)
        
        if #available(iOSApplicationExtension 14.0, *) {
            return self.background(targetColor?.ignoresSafeArea())
        } else {
            return self.background(targetColor)
        }
    }
    
    func shadow(themeColor: ThemeValue, radius: CGFloat) -> some View {
        return self.shadow(
            color: ThemeManager.color(for: themeColor) ?? Color.primary,
            radius: radius
        )
    }
}

public extension Shape {
    func fill(themeColor: ThemeValue) -> some View {
        return self.fill(ThemeManager.color(for: themeColor) ?? Color.primary)
    }
    
    func stroke(themeColor: ThemeValue, lineWidth: CGFloat = 1) -> some View {
        return self.stroke(
            ThemeManager.color(for: themeColor) ?? Color.primary,
            lineWidth: lineWidth
        )
    }
    
    func stroke(themeColor: ThemeValue, style: StrokeStyle) -> some View {
        return self.stroke(
            ThemeManager.color(for: themeColor) ?? Color.primary,
            style: style
        )
    }
}

public extension Color {
    init?(_ value: ThemeValue) {
        guard let result = Color.resolve(value, for: ThemeManager.currentTheme) else { return nil }
        
        self = result
    }
}

public extension Text {
    func foregroundColor(themeColor: ThemeValue) -> Text {
        return self.foregroundColor(ThemeManager.color(for: themeColor))
    }
}

// MARK: - Convenience

private extension ThemeManager {
    static func color<T: ColorType>(for value: ThemeValue) -> T? {
        return ThemeManager.color(for: value, in: currentTheme)
    }
}
