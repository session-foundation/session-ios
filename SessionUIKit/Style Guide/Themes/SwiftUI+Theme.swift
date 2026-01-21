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
        return ThemeColorResolver(themeValue: themeColor) { color in
            self.background(color)
        }
    }
    
    func shadow(themeColor: ThemeValue, radius: CGFloat, x: CGFloat = 0, y: CGFloat = 0) -> some View {
        return ThemeColorResolver(themeValue: themeColor) { color in
            self.shadow(color: color, radius: radius, x: x, y: y)
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

// MARK: - ThemeObserver

@MainActor
class ThemeObserver: ObservableObject {
    static let shared = ThemeObserver()
    
    @Published private(set) var theme: Theme
    @Published private(set) var primaryColor: Theme.PrimaryColor
    
    private init() {
        self.theme = ThemeManager.currentTheme
        self.primaryColor = ThemeManager.primaryColor
        
        // Register for theme changes from UIKit ThemeManager
        ThemeManager.onThemeChange(observer: self) { [weak self] theme, primaryColor, _ in
            guard let self = self else { return }
            
            // Update published properties to trigger SwiftUI view updates
            self.theme = theme
            self.primaryColor = primaryColor
        }
    }
}

// MARK: - ThemeColorResolver

private struct ThemeColorResolver<Content: View>: View {
    @ObservedObject private var observer = ThemeObserver.shared
    
    let themeValue: ThemeValue
    let content: (Color) -> Content
    #if DEBUG
    @Environment(\.previewTheme) private var previewTheme
    #endif
    
    var body: some View {
        var targetTheme: Theme = observer.theme
        var targetPrimaryColor: Theme.PrimaryColor = observer.primaryColor
        
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
