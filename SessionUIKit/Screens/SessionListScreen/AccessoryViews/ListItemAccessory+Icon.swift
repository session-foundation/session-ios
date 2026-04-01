// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Lucide

public extension SessionListScreenContent.ListItemAccessory {
    static func icon(
        _ icon: Lucide.Icon,
        size: IconSize = .medium,
        tintColor: ThemeValue = .textPrimary,
        shouldFill: Bool = false,
        accessibility: Accessibility? = nil
    ) -> SessionListScreenContent.ListItemAccessory {
        return .icon(
            (
                SNUIKit.isRTL ?
                    Lucide.image(icon: icon, size: size.size)?.withHorizontallyFlippedOrientation() :
                    Lucide.image(icon: icon, size: size.size)
            ),
            size: size,
            tintColor: tintColor,
            shouldFill: shouldFill,
            accessibility: accessibility
        )
    }
    
    static func icon(
        _ image: UIImage?,
        size: IconSize = .medium,
        tintColor: ThemeValue = .textPrimary,
        shouldFill: Bool = false,
        accessibility: Accessibility? = nil
    ) -> SessionListScreenContent.ListItemAccessory {
        return SessionListScreenContent.ListItemAccessory(
            padding: Values.smallSpacing
        ) {
            Image(uiImage: image ?? UIImage())
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: (shouldFill ? .fill : .fit))
                .frame(width: size.size, height: size.size)
                .foregroundColor(themeColor: tintColor)
                .accessibility(accessibility)
        }
    }
    
    static func icon(
        _ image: UIImage?,
        iconSize: IconSize = .medium,
        tintColor: ThemeValue = .textPrimary,
        gradientBackgroundColors: [ThemeValue] = [],
        backgroundSize: IconSize = .veryLarge,
        backgroundCornerRadius: CGFloat = 0,
        accessibility: Accessibility? = nil
    ) -> SessionListScreenContent.ListItemAccessory {
        return SessionListScreenContent.ListItemAccessory {
            ZStack {
                ThemeLinearGradient(
                    themeColors: gradientBackgroundColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .frame(width: backgroundSize.size, height: backgroundSize.size)
                .cornerRadius(backgroundCornerRadius)
                
                Image(uiImage: image ?? UIImage())
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: iconSize.size, height: iconSize.size)
                    .foregroundColor(themeColor: tintColor)
                    .accessibility(accessibility)
            }
            .dropShadow(themeColor: .shadow, radius: 2)
        }
    }
}
