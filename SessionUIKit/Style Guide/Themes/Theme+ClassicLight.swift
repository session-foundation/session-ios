// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit.UIColor
import SwiftUI

internal enum Theme_ClassicLight: ThemeColors {
    static let theme: [ThemeValue: UIColor] = [
        // General
        .white: .white,
        .black: .black,
        .clear: .clear,
        .primary: .primary,
        .defaultPrimary: Theme.PrimaryColor.green.color,
        .warning: .warningLight,
        .danger: .dangerLight,
        .disabled: .disabledLight,
        .backgroundPrimary: .classicLight6,
        .backgroundSecondary: .classicLight5,
        .textPrimary: .classicLight0,
        .textSecondary: .classicLight1,
        .borderSeparator: .classicLight3,
        
        // Path
        .path_connected: .pathConnected,
        .path_connecting: .pathConnecting,
        .path_error: .pathError,
        .path_unknown: .classicLight4,
    
        // TextBox
        .textBox_background: .classicLight6,
        .textBox_border: .classicLight2,
    
        // MessageBubble
        .messageBubble_outgoingBackground: .primary,
        .messageBubble_incomingBackground: .classicLight4,
        .messageBubble_outgoingText: .classicLight0,
        .messageBubble_incomingText: .classicLight0,
        .messageBubble_overlay: .black_06,
        .messageBubble_deliveryStatus: .classicLight1,

        // MenuButton
        .menuButton_background: .primary,
        .menuButton_icon: .classicLight6,
        .menuButton_outerShadow: .classicLight0,
        .menuButton_innerShadow: .classicLight6,
        
        // RadioButton
        .radioButton_selectedBackground: .primary,
        .radioButton_unselectedBackground: .clear,
        .radioButton_selectedBorder: .classicLight0,
        .radioButton_unselectedBorder: .classicLight0,
        .radioButton_disabledSelectedBackground: .disabledLight,
        .radioButton_disabledUnselectedBackground: .clear,
        .radioButton_disabledBorder: .disabledLight,
        
        // OutlineButton
        .sessionButton_text: .classicLight0,
        .sessionButton_background: .clear,
        .sessionButton_highlight: .classicLight0.withAlphaComponent(0.1),
        .sessionButton_border: .classicLight0,
        .sessionButton_filledText: .classicLight6,
        .sessionButton_filledBackground: .classicLight0,
        .sessionButton_filledHighlight: .classicLight1,
        .sessionButton_destructiveText: .dangerLight,
        .sessionButton_destructiveBackground: .clear,
        .sessionButton_destructiveHighlight: .dangerLight.withAlphaComponent(0.3),
        .sessionButton_destructiveBorder: .dangerLight,
        .sessionButton_primaryFilledText: .black,
        .sessionButton_primaryFilledBackground: .primary,
        
        // SolidButton
        .solidButton_background: .classicLight3,
        
        // Settings
        .settings_tertiaryAction: .classicLight0,
        .settings_tabBackground: .classicLight5,
        
        // AppearanceButton
        .appearance_sectionBackground: .classicLight6,
        .appearance_buttonBackground: .classicLight6,
        
        // Alert
        .alert_text: .classicLight0,
        .alert_background: .classicLight6,
        .alert_buttonBackground: .classicLight6,
        .toast_background: .classicLight4,
        
        // ConversationButton
        .conversationButton_background: .classicLight6,
        .conversationButton_unreadBackground: .classicLight6,
        .conversationButton_unreadStripBackground: .primary,
        .conversationButton_unreadBubbleBackground: .primary,
        .conversationButton_unreadBubbleText: .classicLight0,
        .conversationButton_swipeDestructive: .dangerLight,
        .conversationButton_swipeSecondary: .classicLight1,
        .conversationButton_swipeTertiary: Theme.PrimaryColor.orange.color,
        .conversationButton_swipeRead: .classicLight3,
        
        // InputButton
        .inputButton_background: .classicLight4,
        
        // ContextMenu
        .contextMenu_background: .classicLight6,
        .contextMenu_highlight: .primary,
        .contextMenu_text: .classicLight0,
        .contextMenu_textHighlight: .classicLight0,
        
        // Call
        .callAccept_background: Theme.PrimaryColor.green.color,
        .callDecline_background: .dangerLight,
        
        // Reactions
        .reactions_contextBackground: .classicLight4,
        .reactions_contextMoreBackground: .classicLight6,
        
        // NewConversation
        .newConversation_background: .classicLight6,
        
        // Profile
        .profileIcon: .primary,
        .profileIcon_greenPrimaryColor: .primary,
        .profileIcon_background: .black,
        
        // Unread Marker
        .unreadMarker: .black
    ]
    
    static let themeSwiftUI: [ThemeValue: Color] = [
        // General
        .white: .white,
        .black: .black,
        .clear: .clear,
        .primary: .primary,
        .defaultPrimary: Theme.PrimaryColor.green.colorSwiftUI,
        .warning: .warning,
        .danger: .dangerLight,
        .disabled: .disabledLight,
        .backgroundPrimary: .classicLight6,
        .backgroundSecondary: .classicLight5,
        .textPrimary: .classicLight0,
        .textSecondary: .classicLight1,
        .borderSeparator: .classicLight2,
        
        // Path
        .path_connected: .pathConnected,
        .path_connecting: .pathConnecting,
        .path_error: .pathError,
        .path_unknown: .classicLight4,
    
        // TextBox
        .textBox_background: .classicLight6,
        .textBox_border: .classicLight2,
    
        // MessageBubble
        .messageBubble_outgoingBackground: .primary,
        .messageBubble_incomingBackground: .classicLight4,
        .messageBubble_outgoingText: .classicLight0,
        .messageBubble_incomingText: .classicLight0,
        .messageBubble_overlay: .black_06,
        .messageBubble_deliveryStatus: .classicLight1,

        // MenuButton
        .menuButton_background: .primary,
        .menuButton_icon: .classicLight6,
        .menuButton_outerShadow: .classicLight0,
        .menuButton_innerShadow: .classicLight6,
        
        // RadioButton
        .radioButton_selectedBackground: .primary,
        .radioButton_unselectedBackground: .clear,
        .radioButton_selectedBorder: .classicLight0,
        .radioButton_unselectedBorder: .classicLight0,
        .radioButton_disabledSelectedBackground: .disabledLight,
        .radioButton_disabledUnselectedBackground: .clear,
        .radioButton_disabledBorder: .disabledLight,
        
        // OutlineButton
        .sessionButton_text: .classicLight0,
        .sessionButton_background: .clear,
        .sessionButton_highlight: .classicLight0.opacity(0.1),
        .sessionButton_border: .classicLight0,
        .sessionButton_filledText: .classicLight6,
        .sessionButton_filledBackground: .classicLight0,
        .sessionButton_filledHighlight: .classicLight1,
        .sessionButton_destructiveText: .dangerLight,
        .sessionButton_destructiveBackground: .clear,
        .sessionButton_destructiveHighlight: .dangerLight.opacity(0.3),
        .sessionButton_destructiveBorder: .dangerLight,
        .sessionButton_primaryFilledText: .black,
        .sessionButton_primaryFilledBackground: .primary,
        
        // SolidButton
        .solidButton_background: .classicLight3,
        
        // Settings
        .settings_tertiaryAction: .classicLight0,
        .settings_tabBackground: .classicLight5,
        
        // AppearanceButton
        .appearance_sectionBackground: .classicLight6,
        .appearance_buttonBackground: .classicLight6,
        
        // Alert
        .alert_text: .classicLight0,
        .alert_background: .classicLight6,
        .alert_buttonBackground: .classicLight6,
        .toast_background: .classicLight4,
        
        // ConversationButton
        .conversationButton_background: .classicLight6,
        .conversationButton_unreadBackground: .classicLight6,
        .conversationButton_unreadStripBackground: .primary,
        .conversationButton_unreadBubbleBackground: .classicLight3,
        .conversationButton_unreadBubbleText: .classicLight0,
        .conversationButton_swipeDestructive: .dangerLight,
        .conversationButton_swipeSecondary: .classicLight1,
        .conversationButton_swipeTertiary: Theme.PrimaryColor.orange.colorSwiftUI,
        .conversationButton_swipeRead: .classicLight3,
        
        // InputButton
        .inputButton_background: .classicLight4,
        
        // ContextMenu
        .contextMenu_background: .classicLight6,
        .contextMenu_highlight: .primary,
        .contextMenu_text: .classicLight0,
        .contextMenu_textHighlight: .classicLight0,
        
        // Call
        .callAccept_background: Theme.PrimaryColor.green.colorSwiftUI,
        .callDecline_background: .dangerLight,
        
        // Reactions
        .reactions_contextBackground: .classicLight4,
        .reactions_contextMoreBackground: .classicLight6,
        
        // NewConversation
        .newConversation_background: .classicLight6,
        
        // Profile
        .profileIcon: .primary,
        .profileIcon_greenPrimaryColor: .primary,
        .profileIcon_background: .black,
        
        // Unread Marker
        .unreadMarker: .black
    ]
}
