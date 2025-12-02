// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SwiftUI

public enum SessionListScreenContent {}

public extension SessionListScreenContent {
    protocol ViewModelType: ObservableObject, SectionedListItemData {
        var title: String { get }
        var state: ListItemDataState<Section, ListItem> { get }
    }
    
    struct TooltipInfo: Hashable, Equatable {
        let id: String
        let content: ThemedAttributedString
        let tintColor: ThemeValue
        let position: ViewPosition
        
        public init(
            id: String,
            content: ThemedAttributedString,
            tintColor: ThemeValue,
            position: ViewPosition
        ) {
            self.id = id
            self.content = content
            self.tintColor = tintColor
            self.position = position
            
        }
    }
    
    struct TextInfo: Hashable, Equatable {
        public enum Accessory: Hashable, Equatable {
            case proBadgeLeading(
                size: SessionProBadge.Size,
                themeBackgroundColor: ThemeValue
            )
            case proBadgeTrailing(
                size: SessionProBadge.Size,
                themeBackgroundColor: ThemeValue
            )
            case none
        }
        
        let text: String?
        let font: Font?
        let attributedString: ThemedAttributedString?
        let alignment: TextAlignment
        let color: ThemeValue
        let accessory: Accessory
        let accessibility: Accessibility?
        
        public init(
            _ text: String? = nil,
            font: Font? = nil,
            attributedString: ThemedAttributedString? = nil,
            alignment: TextAlignment = .leading,
            color: ThemeValue = .textPrimary,
            accessory: Accessory = .none,
            accessibility: Accessibility? = nil
        ) {
            self.text = text
            self.font = font
            self.attributedString = attributedString
            self.alignment = alignment
            self.color = color
            self.accessory = accessory
            self.accessibility = accessibility
        }
        
        // MARK: - Conformance
        
        public func hash(into hasher: inout Hasher) {
            text.hash(into: &hasher)
            font.hash(into: &hasher)
            attributedString.hash(into: &hasher)
            alignment.hash(into: &hasher)
            color.hash(into: &hasher)
            accessory.hash(into: &hasher)
            accessibility.hash(into: &hasher)
        }
        
        public static func == (lhs: TextInfo, rhs: TextInfo) -> Bool {
            return (
                lhs.text == rhs.text &&
                lhs.font == rhs.font &&
                lhs.attributedString == rhs.attributedString &&
                lhs.alignment == rhs.alignment &&
                lhs.color == rhs.color &&
                lhs.accessory == rhs.accessory &&
                lhs.accessibility == rhs.accessibility
            )
        }
    }
}
