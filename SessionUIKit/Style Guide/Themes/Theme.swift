// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit.UIColor
import SwiftUI

// MARK: - Theme

public enum Theme: Int, Sendable, CaseIterable, Codable {
    public static var defaultTheme: Theme = .classicDark
    
    case classicDark
    case classicLight
    case oceanDark
    case oceanLight
    
    // MARK: - Properties
    
    public var title: String {
        switch self {
            case .classicDark: return "appearanceThemesClassicDark".localized()
            case .classicLight: return "appearanceThemesClassicLight".localized()
            case .oceanDark: return "appearanceThemesOceanDark".localized()
            case .oceanLight: return "appearanceThemesOceanLight".localized()
        }
    }
    
    public var interfaceStyle: UIUserInterfaceStyle {
        switch self {
            case .classicDark, .oceanDark: return .dark
            case .classicLight, .oceanLight: return .light
        }
    }
    
    public var statusBarStyle: UIStatusBarStyle {
        switch self {
            case .classicDark, .oceanDark: return .lightContent
            case .classicLight, .oceanLight: return .darkContent
        }
    }
    
    public var keyboardAppearance: UIKeyboardAppearance {
        switch self {
            case .classicDark, .oceanDark: return .dark
            case .classicLight, .oceanLight: return .default
        }
    }
    
    public var blurStyle: UIBlurEffect.Style {
        switch self {
            case .classicDark, .oceanDark: return .dark
            case .classicLight, .oceanLight: return .light
        }
    }
    
    fileprivate var colors: [ThemeValue: UIColor] {
        switch self {
            case .classicDark: return Theme_ClassicDark.theme
            case .classicLight: return Theme_ClassicLight.theme
            case .oceanDark: return Theme_OceanDark.theme
            case .oceanLight: return Theme_OceanLight.theme
        }
    }
    
    fileprivate var colorsSwiftUI: [ThemeValue: Color] {
        switch self {
            case .classicDark: return Theme_ClassicDark.themeSwiftUI
            case .classicLight: return Theme_ClassicLight.themeSwiftUI
            case .oceanDark: return Theme_OceanDark.themeSwiftUI
            case .oceanLight: return Theme_OceanLight.themeSwiftUI
        }
    }
    
    internal var defaultPrimary: Theme.PrimaryColor {
        let maybeTargetColor: Color? = {
            switch self {
                case .classicDark: return Theme_ClassicDark.themeSwiftUI[.defaultPrimary]
                case .classicLight: return Theme_ClassicLight.themeSwiftUI[.defaultPrimary]
                case .oceanDark: return Theme_OceanDark.themeSwiftUI[.defaultPrimary]
                case .oceanLight: return Theme_OceanLight.themeSwiftUI[.defaultPrimary]
            }
        }()
        
        guard let targetColor: Color = maybeTargetColor else { return .green }
        
        return (Theme.PrimaryColor.allCases.first(where: { $0.colorSwiftUI == targetColor }) ?? .green)
    }
}

// MARK: - ColorType Convenience

internal extension ColorType {
    static func resolve(_ value: ThemeValue, for theme: Theme) -> Self? {
        switch Self.self {
            case is UIColor.Type: return theme.colors[value] as? Self
            case is Color.Type: return theme.colorsSwiftUI[value] as? Self
            default: return nil
        }
    }
}

// MARK: - ThemeColors

public protocol ThemeColors {
    static var theme: [ThemeValue: UIColor] { get }
    static var themeSwiftUI: [ThemeValue: Color] { get }
}

// MARK: - ThemedNavigation

public protocol ThemedNavigation {
    var navigationBackground: ThemeValue? { get }
}

// MARK: - ThemeValue

public indirect enum ThemeValue: Hashable, Equatable {
    case value(ThemeValue, alpha: CGFloat)
    case explicitPrimary(Theme.PrimaryColor)
    case dynamicForInterfaceStyle(light: ThemeValue, dark: ThemeValue)
    case dynamicForPrimary(Theme.PrimaryColor, use: ThemeValue, otherwise: ThemeValue)
    
    // The 'highlighted' state of a color will automatically lighten/darken a ThemeValue
    // by a fixed amount depending on wither the theme is dark/light mode
    case highlighted(ThemeValue, alwaysDarken: Bool)
    
    public static func highlighted(_ value: ThemeValue) -> ThemeValue {
        return .highlighted(value, alwaysDarken: false)
    }
    
    // General
    case white
    case black
    case clear
    case primary
    case defaultPrimary
    case warning
    case danger
    case disabled
    case backgroundPrimary
    case backgroundSecondary
    case textPrimary
    case textSecondary
    case borderSeparator
    
    // Path
    case path_connected
    case path_connecting
    case path_error
    case path_unknown
    
    // TextBox
    case textBox_background
    case textBox_border
    
    // MessageBubble
    case messageBubble_outgoingBackground
    case messageBubble_incomingBackground
    case messageBubble_outgoingText
    case messageBubble_incomingText
    case messageBubble_overlay
    case messageBubble_deliveryStatus
    
    // MenuButton
    case menuButton_background
    case menuButton_icon
    case menuButton_outerShadow
    case menuButton_innerShadow
    
    // RadioButton
    case radioButton_selectedBackground
    case radioButton_unselectedBackground
    case radioButton_selectedBorder
    case radioButton_unselectedBorder
    case radioButton_disabledSelectedBackground
    case radioButton_disabledUnselectedBackground
    case radioButton_disabledBorder
    
    // SessionButton
    case sessionButton_text
    case sessionButton_background
    case sessionButton_highlight
    case sessionButton_border
    case sessionButton_filledText
    case sessionButton_filledBackground
    case sessionButton_filledHighlight
    case sessionButton_destructiveText
    case sessionButton_destructiveBackground
    case sessionButton_destructiveHighlight
    case sessionButton_destructiveBorder
    case sessionButton_primaryFilledText
    case sessionButton_primaryFilledBackground
    
    // SolidButton
    case solidButton_background
    
    // Settings
    case settings_tertiaryAction
    case settings_tabBackground
    case settings_glowingBackground
    
    // Appearance
    case appearance_sectionBackground
    case appearance_buttonBackground
    
    // Alert
    case alert_text
    case alert_background
    case alert_buttonBackground
    case toast_background
    
    // ConversationButton
    case conversationButton_background
    case conversationButton_unreadBackground
    case conversationButton_unreadStripBackground
    case conversationButton_unreadBubbleBackground
    case conversationButton_unreadBubbleText
    case conversationButton_swipeDestructive
    case conversationButton_swipeSecondary
    case conversationButton_swipeTertiary
    case conversationButton_swipeRead
    
    // InputButton
    case inputButton_background
    
    // ContextMenu
    case contextMenu_background
    case contextMenu_highlight
    case contextMenu_text
    case contextMenu_textHighlight
    
    // Call
    case callAccept_background
    case callDecline_background
    
    // Reactions
    case reactions_contextBackground
    case reactions_contextMoreBackground
    
    // NewConversation
    case newConversation_background
    
    // Profile
    case profileIcon
    case profileIcon_greenPrimaryColor
    case profileIcon_background
    
    // Unread Marker
    case unreadMarker
}

// MARK: - ForcedThemeValue

public enum ForcedThemeValue {
    case color(UIColor)
    case theme(Theme, color: ThemeValue, alpha: CGFloat?)
    
    public static func theme(_ theme: Theme, color: ThemeValue) -> ForcedThemeValue {
        return .theme(theme, color: color, alpha: nil)
    }
}
