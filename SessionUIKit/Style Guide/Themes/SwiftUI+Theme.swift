// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

public extension View {
    @ViewBuilder
    func foregroundColor(themeColor: ThemeValue?) -> some View {
        if let themeColor {
            ThemeColorResolver(themeValue: themeColor) { color in
                self.foregroundColor(color)
            }
        } else {
            self
        }
    }
    
    @ViewBuilder
    func tint(themeColor: ThemeValue?) -> some View {
        if let themeColor {
            ThemeColorResolver(themeValue: themeColor) { color in
                self.tint(color)
            }
        } else {
            self
        }
    }
    
    func backgroundColor(themeColor: ThemeValue) -> some View {
        if #available(iOSApplicationExtension 14.0, *) {
            return ThemeColorResolver(themeValue: themeColor) { color in
                self.background(color.ignoresSafeArea())
            }
        }
        else {
            return ThemeColorResolver(themeValue: themeColor) { color in
                self.background(color)
            }
        }
    }
    
    func shadow(themeColor: ThemeValue, radius: CGFloat) -> some View {
        return ThemeColorResolver(themeValue: themeColor) { color in
            self.shadow(color: color, radius: radius)
        }
    }
}

public extension Shape {
    func fill(themeColor: ThemeValue) -> some View {
        return ThemeColorResolver(themeValue: themeColor) { color in
            self.fill(color)
        }
    }
    
    func stroke(themeColor: ThemeValue, lineWidth: CGFloat = 1) -> some View {
        return ThemeColorResolver(themeValue: themeColor) { color in
            self.stroke(color, lineWidth: lineWidth)
        }
    }
    
    func stroke(themeColor: ThemeValue, style: StrokeStyle) -> some View {
        return ThemeColorResolver(themeValue: themeColor) { color in
            self.stroke(color, style: style)
        }
    }
}

// MARK: - ThemeColorResolver

private struct ThemeColorResolver<Content: View>: View {
    let themeValue: ThemeValue
    let content: (Color) -> Content
    #if DEBUG
    @Environment(\.previewTheme) private var previewTheme
    #endif
    
    var body: some View {
        var targetTheme: Theme = ThemeManager.currentTheme
        var targetPrimaryColor: Theme.PrimaryColor = ThemeManager.primaryColor
        
        #if DEBUG
        if let (theme, primaryColor) = previewTheme {
            targetTheme = theme
            targetPrimaryColor = primaryColor
        }
        #endif
        
        let color: Color? = ThemeManager.color(for: themeValue, in: targetTheme, with: targetPrimaryColor)
        return content(color ?? .clear)
    }
}
