// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit.UIColor
import SwiftUI

internal enum Theme_OceanLight: ThemeColors {
    static let theme: [ThemeValue: UIColor] = [
        // General
        .white: .white,
        .black: .black,
        .clear: .clear,
        .primary: .primary,
        .defaultPrimary: Theme.PrimaryColor.blue.color,
        .warning: .warningLight,
        .danger: .dangerLight,
        .disabled: .disabledLight,
        .backgroundPrimary: .oceanLight7,
        .backgroundSecondary: .oceanLight6,
        .textPrimary: .oceanLight1,
        .textSecondary: .oceanLight2,
        .borderSeparator: .oceanLight3,
        
        // Path
        .path_connected: .pathConnected,
        .path_connecting: .pathConnecting,
        .path_error: .pathError,
        .path_unknown: .oceanLight5,
    
        // TextBox
        .textBox_background: .oceanLight7,
        .textBox_border: .oceanLight3,
    
        // MessageBubble
        .messageBubble_outgoingBackground: .primary,
        .messageBubble_incomingBackground: .oceanLight4,
        .messageBubble_outgoingText: .oceanLight1,
        .messageBubble_incomingText: .oceanLight1,
        .messageBubble_overlay: .black_06,
        .messageBubble_deliveryStatus: .oceanLight2,

        // MenuButton
        .menuButton_background: .primary,
        .menuButton_icon: .white,
        .menuButton_outerShadow: .black,
        .menuButton_innerShadow: .white,
        
        // RadioButton
        .radioButton_selectedBackground: .primary,
        .radioButton_unselectedBackground: .clear,
        .radioButton_selectedBorder: .oceanLight1,
        .radioButton_unselectedBorder: .oceanLight3,
        .radioButton_disabledSelectedBackground: .disabledLight,
        .radioButton_disabledUnselectedBackground: .clear,
        .radioButton_disabledBorder: .disabledLight,
        
        // SessionButton
        .sessionButton_text: .oceanLight1,
        .sessionButton_background: .clear,
        .sessionButton_highlight: .oceanLight1.withAlphaComponent(0.1),
        .sessionButton_border: .oceanLight1,
        .sessionButton_filledText: .oceanLight7,
        .sessionButton_filledBackground: .oceanLight1,
        .sessionButton_filledHighlight: .oceanLight2,
        .sessionButton_destructiveText: .dangerLight,
        .sessionButton_destructiveBackground: .clear,
        .sessionButton_destructiveHighlight: .dangerLight.withAlphaComponent(0.3),
        .sessionButton_destructiveBorder: .dangerLight,
        .sessionButton_primaryFilledText: .black,
        .sessionButton_primaryFilledBackground: .primary,
        
        // SolidButton
        .solidButton_background: .oceanLight5,
        
        // Settings
        .settings_tertiaryAction: .oceanLight1,
        .settings_tabBackground: .oceanLight6,
        
        // Appearance
        .appearance_sectionBackground: .oceanLight7,
        .appearance_buttonBackground: .oceanLight7,
        
        // Alert
        .alert_text: .oceanLight0,
        .alert_background: .oceanLight7,
        .alert_buttonBackground: .oceanLight7,
        .toast_background: .oceanLight5,
        
        // ConversationButton
        .conversationButton_background: .oceanLight7,
        .conversationButton_unreadBackground: .oceanLight6,
        .conversationButton_unreadStripBackground: .primary,
        .conversationButton_unreadBubbleBackground: .primary,
        .conversationButton_unreadBubbleText: .oceanLight1,
        .conversationButton_swipeDestructive: .dangerLight,
        .conversationButton_swipeSecondary: .oceanLight2,
        .conversationButton_swipeTertiary: Theme.PrimaryColor.orange.color,
        .conversationButton_swipeRead: .primary,
        
        // InputButton
        .inputButton_background: .oceanLight5,
        
        // ContextMenu
        .contextMenu_background: .oceanLight7,
        .contextMenu_highlight: .primary,
        .contextMenu_text: .oceanLight0,
        .contextMenu_textHighlight: .oceanLight0,
        
        // Call
        .callAccept_background: Theme.PrimaryColor.green.color,
        .callDecline_background: .dangerLight,
        
        // Reactions
        .reactions_contextBackground: .oceanLight7,
        .reactions_contextMoreBackground: .oceanLight6,
        
        // NewConversation
        .newConversation_background: .oceanLight7,
        
        // Profile
        .profileIcon: .primary,
        .profileIcon_greenPrimaryColor: .primary,
        .profileIcon_background: .oceanLight1,
        
        // Unread Marker
        .unreadMarker: .black
    ]
    
    static let themeSwiftUI: [ThemeValue: Color] = [
        // General
        .white: .white,
        .black: .black,
        .clear: .clear,
        .primary: .primary,
        .defaultPrimary: Theme.PrimaryColor.blue.colorSwiftUI,
        .warning: .warning,
        .danger: .dangerLight,
        .disabled: .disabledLight,
        .backgroundPrimary: .oceanLight7,
        .backgroundSecondary: .oceanLight6,
        .textPrimary: .oceanLight1,
        .textSecondary: .oceanLight2,
        .borderSeparator: .oceanLight3,
        
        // Path
        .path_connected: .pathConnected,
        .path_connecting: .pathConnecting,
        .path_error: .pathError,
        .path_unknown: .oceanLight5,
    
        // TextBox
        .textBox_background: .oceanLight7,
        .textBox_border: .oceanLight3,
    
        // MessageBubble
        .messageBubble_outgoingBackground: .primary,
        .messageBubble_incomingBackground: .oceanLight4,
        .messageBubble_outgoingText: .oceanLight1,
        .messageBubble_incomingText: .oceanLight1,
        .messageBubble_overlay: .black_06,
        .messageBubble_deliveryStatus: .oceanLight2,

        // MenuButton
        .menuButton_background: .primary,
        .menuButton_icon: .white,
        .menuButton_outerShadow: .black,
        .menuButton_innerShadow: .white,
        
        // RadioButton
        .radioButton_selectedBackground: .primary,
        .radioButton_unselectedBackground: .clear,
        .radioButton_selectedBorder: .oceanLight1,
        .radioButton_unselectedBorder: .oceanLight3,
        .radioButton_disabledSelectedBackground: .disabledLight,
        .radioButton_disabledUnselectedBackground: .clear,
        .radioButton_disabledBorder: .disabledLight,
        
        // SessionButton
        .sessionButton_text: .oceanLight1,
        .sessionButton_background: .clear,
        .sessionButton_highlight: .oceanLight1.opacity(0.1),
        .sessionButton_border: .oceanLight1,
        .sessionButton_filledText: .oceanLight7,
        .sessionButton_filledBackground: .oceanLight1,
        .sessionButton_filledHighlight: .oceanLight2,
        .sessionButton_destructiveText: .dangerLight,
        .sessionButton_destructiveBackground: .clear,
        .sessionButton_destructiveHighlight: .dangerLight.opacity(0.3),
        .sessionButton_destructiveBorder: .dangerLight,
        .sessionButton_primaryFilledText: .black,
        .sessionButton_primaryFilledBackground: .primary,
        
        // SolidButton
        .solidButton_background: .oceanLight5,
        
        // Settings
        .settings_tertiaryAction: .oceanLight1,
        .settings_tabBackground: .oceanLight6,
        
        // Appearance
        .appearance_sectionBackground: .oceanLight7,
        .appearance_buttonBackground: .oceanLight7,
        
        // Alert
        .alert_text: .oceanLight0,
        .alert_background: .oceanLight7,
        .alert_buttonBackground: .oceanLight7,
        .toast_background: .oceanLight5,
        
        // ConversationButton
        .conversationButton_background: .oceanLight7,
        .conversationButton_unreadBackground: .oceanLight6,
        .conversationButton_unreadStripBackground: .primary,
        .conversationButton_unreadBubbleBackground: .primary,
        .conversationButton_unreadBubbleText: .oceanLight1,
        .conversationButton_swipeDestructive: .dangerLight,
        .conversationButton_swipeSecondary: .oceanLight2,
        .conversationButton_swipeTertiary: Theme.PrimaryColor.orange.colorSwiftUI,
        .conversationButton_swipeRead: .primary,
        
        // InputButton
        .inputButton_background: .oceanLight5,
        
        // ContextMenu
        .contextMenu_background: .oceanLight7,
        .contextMenu_highlight: .primary,
        .contextMenu_text: .oceanLight0,
        .contextMenu_textHighlight: .oceanLight0,
        
        // Call
        .callAccept_background: Theme.PrimaryColor.green.colorSwiftUI,
        .callDecline_background: .dangerLight,
        
        // Reactions
        .reactions_contextBackground: .oceanLight7,
        .reactions_contextMoreBackground: .oceanLight6,
        
        // NewConversation
        .newConversation_background: .oceanLight7,
        
        // Profile
        .profileIcon: .primary,
        .profileIcon_greenPrimaryColor: .primary,
        .profileIcon_background: .oceanLight1,
        
        // Unread Marker
        .unreadMarker: .black
    ]
}
