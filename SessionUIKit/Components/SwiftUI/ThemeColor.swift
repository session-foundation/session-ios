// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

public struct ThemeColor: View {
    let value: ThemeValue
    @State private var currentColor: Color = .clear
    #if DEBUG
    @Environment(\.previewTheme) private var previewTheme
    #endif
    
    public init(_ value: ThemeValue) {
        self.value = value
    }
    
    public var body: some View {
        currentColor
            .onAppear {
                updateColor()
            }
            .onChange(of: value) { _ in
                updateColor()
            }
    }
    
    private func updateColor() {
        var targetTheme: Theme = ThemeManager.currentTheme
        var targetPrimaryColor: Theme.PrimaryColor = ThemeManager.primaryColor
        
        #if DEBUG
        if let (theme, primaryColor) = previewTheme {
            targetTheme = theme
            targetPrimaryColor = primaryColor
        }
        #endif
        
        let color: Color? = ThemeManager.color(for: value, in: targetTheme, with: targetPrimaryColor)
        currentColor = (color ?? Color.clear)
    }
}

struct ThemeColor_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            PreviewThemeWrapper(theme: .classicDark) {
                ThemeColor(.primary)
                    .previewDisplayName("Classic Dark")
            }
            PreviewThemeWrapper(theme: .classicLight) {
                ThemeColor(.primary)
                    .previewDisplayName("Classic Light")
            }
            PreviewThemeWrapper(theme: .oceanDark) {
                ThemeColor(.primary)
                    .previewDisplayName("Ocean Dark")
            }
            PreviewThemeWrapper(theme: .oceanLight) {
                ThemeColor(.primary)
                    .previewDisplayName("Ocean Light")
            }
        }
    }
}
