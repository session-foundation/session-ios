// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

public struct ThemeLinearGradient: View {
    let themeColors: [ThemeValue]
    let startPoint: UnitPoint
    let endPoint: UnitPoint
    #if DEBUG
    @Environment(\.previewTheme) private var previewTheme
    #endif
    
    public init(themeColors: [ThemeValue], startPoint: UnitPoint, endPoint: UnitPoint) {
        self.themeColors = themeColors
        self.startPoint = startPoint
        self.endPoint = endPoint
    }
    
    public var body: some View {
        var targetTheme: Theme = ThemeManager.currentTheme
        var targetPrimaryColor: Theme.PrimaryColor = ThemeManager.primaryColor
        
        #if DEBUG
        if let (theme, primaryColor) = previewTheme {
            targetTheme = theme
            targetPrimaryColor = primaryColor
        }
        #endif
        
        let colors = themeColors.map { ThemeManager.color(for: $0, in: targetTheme, with: targetPrimaryColor) ?? Color.clear }
        
        return LinearGradient(colors: colors, startPoint: startPoint, endPoint: endPoint)
    }
}
