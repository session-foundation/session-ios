// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit.UIColor
import SwiftUI

internal enum Theme_OceanDark: ThemeColors {
    static let theme: [ThemeValue: UIColor] = [
        // General
        .white: .white,
        .black: .black,
        .clear: .clear,
        .primary: .primary(),
        .defaultPrimary: Theme.PrimaryColor.blue.color,
        .warning: .warningDark,
        .danger: .dangerDark,
        .disabled: .disabledDark,
        .backgroundPrimary: .oceanDark2,
        .backgroundSecondary: .oceanDark1,
        .textPrimary: .oceanDark7,
        .textSecondary: .oceanDark5,
        .borderSeparator: .oceanDark4,
        
        // Path
        .path_connected: .pathConnected,
        .path_connecting: .pathConnecting,
        .path_error: .pathError,
        .path_unknown: .oceanDark4,
    
        // TextBox
        .textBox_background: .oceanDark1,
        .textBox_border: .oceanDark4,
    
        // MessageBubble
        .messageBubble_outgoingBackground: .primary(),
        .messageBubble_incomingBackground: .oceanDark4,
        .messageBubble_outgoingText: .oceanDark0,
        .messageBubble_incomingText: .oceanDark7,
        .messageBubble_overlay: .black_06,
        .messageBubble_deliveryStatus: .oceanDark5,

        // MenuButton
        .menuButton_background: .primary(),
        .menuButton_icon: .oceanDark7,
        .menuButton_outerShadow: .primary(),
        .menuButton_innerShadow: .oceanDark7,
        
        // RadioButton
        .radioButton_selectedBackground: .primary(),
        .radioButton_unselectedBackground: .clear,
        .radioButton_selectedBorder: .oceanDark7,
        .radioButton_unselectedBorder: .oceanDark7,
        .radioButton_disabledSelectedBackground: .disabledDark,
        .radioButton_disabledUnselectedBackground: .clear,
        .radioButton_disabledBorder: .disabledDark,
        
        // SessionButton
        .sessionButton_text: .primary(),
        .sessionButton_background: .clear,
        .sessionButton_highlight: .oceanDark7.withAlphaComponent(0.3),
        .sessionButton_border: .primary(),
        .sessionButton_filledText: .oceanDark7,
        .sessionButton_filledBackground: .oceanDark1,
        .sessionButton_filledHighlight: .oceanDark3,
        .sessionButton_destructiveText: .dangerDark,
        .sessionButton_destructiveBackground: .clear,
        .sessionButton_destructiveHighlight: .dangerDark.withAlphaComponent(0.3),
        .sessionButton_destructiveBorder: .dangerDark,
        .sessionButton_primaryFilledText: .black,
        .sessionButton_primaryFilledBackground: .primary(),
        
        // SolidButton
        .solidButton_background: .oceanDark2,
        
        // Settings
        .settings_tertiaryAction: .primary(),
        .settings_tabBackground: .oceanDark1,
        .settings_glowingBackground: .primary(),
        
        // Appearance
        .appearance_sectionBackground: .oceanDark3,
        .appearance_buttonBackground: .oceanDark3,
        
        // Alert
        .alert_text: .oceanDark7,
        .alert_background: .oceanDark3,
        .alert_buttonBackground: .oceanDark3,
        .toast_background: .oceanDark4,
        
        // ConversationButton
        .conversationButton_background: .oceanDark2,
        .conversationButton_unreadBackground: .oceanDark3,
        .conversationButton_unreadStripBackground: .primary(),
        .conversationButton_unreadBubbleBackground: .primary(),
        .conversationButton_unreadBubbleText: .oceanDark0,
        .conversationButton_swipeDestructive: .dangerDark,
        .conversationButton_swipeSecondary: .oceanDark2,
        .conversationButton_swipeTertiary: Theme.PrimaryColor.orange.color,
        .conversationButton_swipeRead: .primary(),
        
        // InputButton
        .inputButton_background: .oceanDark4,
        
        // ContextMenu
        .contextMenu_background: .oceanDark2,
        .contextMenu_highlight: .primary(),
        .contextMenu_text: .oceanDark7,
        .contextMenu_textHighlight: .oceanDark0,
        
        // Call
        .callAccept_background: Theme.PrimaryColor.green.color,
        .callDecline_background: .dangerDark,
        
        // Reactions
        .reactions_contextBackground: .oceanDark1,
        .reactions_contextMoreBackground: .oceanDark2,
        
        // NewConversation
        .newConversation_background: .oceanDark3,
        
        // Profile
        .profileIcon: .primary(),
        .profileIcon_greenPrimaryColor: .black,
        .profileIcon_background: .white,
        
        // Unread Marker
        .unreadMarker: .primary()
    ]
    
    static let themeSwiftUI: [ThemeValue: Color] = [
        // General
        .white: .white,
        .black: .black,
        .clear: .clear,
        .primary: .primary(),
        .defaultPrimary: Theme.PrimaryColor.blue.colorSwiftUI,
        .warning: .warning,
        .danger: .dangerDark,
        .disabled: .disabledDark,
        .backgroundPrimary: .oceanDark2,
        .backgroundSecondary: .oceanDark1,
        .textPrimary: .oceanDark7,
        .textSecondary: .oceanDark5,
        .borderSeparator: .oceanDark4,
        
        // Path
        .path_connected: .pathConnected,
        .path_connecting: .pathConnecting,
        .path_error: .pathError,
        .path_unknown: .oceanDark4,
    
        // TextBox
        .textBox_background: .oceanDark1,
        .textBox_border: .oceanDark4,
    
        // MessageBubble
        .messageBubble_outgoingBackground: .primary(),
        .messageBubble_incomingBackground: .oceanDark4,
        .messageBubble_outgoingText: .oceanDark0,
        .messageBubble_incomingText: .oceanDark7,
        .messageBubble_overlay: .black_06,
        .messageBubble_deliveryStatus: .oceanDark5,

        // MenuButton
        .menuButton_background: .primary(),
        .menuButton_icon: .oceanDark7,
        .menuButton_outerShadow: .primary(),
        .menuButton_innerShadow: .oceanDark7,
        
        // RadioButton
        .radioButton_selectedBackground: .primary(),
        .radioButton_unselectedBackground: .clear,
        .radioButton_selectedBorder: .oceanDark7,
        .radioButton_unselectedBorder: .oceanDark7,
        .radioButton_disabledSelectedBackground: .disabledDark,
        .radioButton_disabledUnselectedBackground: .clear,
        .radioButton_disabledBorder: .disabledDark,
        
        // SessionButton
        .sessionButton_text: .primary(),
        .sessionButton_background: .clear,
        .sessionButton_highlight: .oceanDark7.opacity(0.3),
        .sessionButton_border: .primary(),
        .sessionButton_filledText: .oceanDark7,
        .sessionButton_filledBackground: .oceanDark1,
        .sessionButton_filledHighlight: .oceanDark3,
        .sessionButton_destructiveText: .dangerDark,
        .sessionButton_destructiveBackground: .clear,
        .sessionButton_destructiveHighlight: .dangerDark.opacity(0.3),
        .sessionButton_destructiveBorder: .dangerDark,
        .sessionButton_primaryFilledText: .black,
        .sessionButton_primaryFilledBackground: .primary(),
        
        // SolidButton
        .solidButton_background: .oceanDark2,
        
        // Settings
        .settings_tertiaryAction: .primary(),
        .settings_tabBackground: .oceanDark1,
        .settings_glowingBackground: .primary(),
        
        // Appearance
        .appearance_sectionBackground: .oceanDark3,
        .appearance_buttonBackground: .oceanDark3,
        
        // Alert
        .alert_text: .oceanDark7,
        .alert_background: .oceanDark3,
        .alert_buttonBackground: .oceanDark3,
        .toast_background: .oceanDark4,
        
        // ConversationButton
        .conversationButton_background: .oceanDark3,
        .conversationButton_unreadBackground: .oceanDark4,
        .conversationButton_unreadStripBackground: .primary(),
        .conversationButton_unreadBubbleBackground: .primary(),
        .conversationButton_unreadBubbleText: .oceanDark0,
        .conversationButton_swipeDestructive: .dangerDark,
        .conversationButton_swipeSecondary: .oceanDark2,
        .conversationButton_swipeTertiary: Theme.PrimaryColor.orange.colorSwiftUI,
        .conversationButton_swipeRead: .primary(),
        
        // InputButton
        .inputButton_background: .oceanDark4,
        
        // ContextMenu
        .contextMenu_background: .oceanDark2,
        .contextMenu_highlight: .primary(),
        .contextMenu_text: .oceanDark7,
        .contextMenu_textHighlight: .oceanDark0,
        
        // Call
        .callAccept_background: Theme.PrimaryColor.green.colorSwiftUI,
        .callDecline_background: .dangerDark,
        
        // Reactions
        .reactions_contextBackground: .oceanDark1,
        .reactions_contextMoreBackground: .oceanDark2,
        
        // NewConversation
        .newConversation_background: .oceanDark3,
        
        // Profile
        .profileIcon: .primary(),
        .profileIcon_greenPrimaryColor: .black,
        .profileIcon_background: .white,
        
        // Unread Marker
        .unreadMarker: .primary
    ]
}
