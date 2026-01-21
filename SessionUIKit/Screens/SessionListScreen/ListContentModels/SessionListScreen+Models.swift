// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import UIKit
import SwiftUI
import Combine

public enum SessionListScreenContent {}

// MARK: - ViewModelType

public extension SessionListScreenContent {
    protocol ViewModelType: ObservableObject, SectionedListItemData {
        var title: String { get }
        var state: ListItemDataState<Section, ListItem> { get }
        var imageDataManager: ImageDataManagerType { get }
        associatedtype FooterView: View
        @ViewBuilder var footerView: FooterView { get }
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
        public enum InlineImagePosition: Hashable, Equatable {
            case leading
            case trailing
        }
        
        public enum Interaction: Hashable, Equatable {
            case none
            case copy
            case expandable
        }
        
        public struct InlineImageInfo: Hashable, Equatable {
            let image: UIImage
            let position: InlineImagePosition
            
            public init(image: UIImage, position: InlineImagePosition) {
                self.image = image
                self.position = position
            }
        }
        
        let text: String?
        let font: Font?
        let attributedString: ThemedAttributedString?
        let alignment: TextAlignment
        let color: ThemeValue
        let interaction: Interaction
        let accessibility: Accessibility?
        let inlineImage: InlineImageInfo?
        
        public init(
            _ text: String? = nil,
            font: Font? = nil,
            attributedString: ThemedAttributedString? = nil,
            alignment: TextAlignment = .leading,
            color: ThemeValue = .textPrimary,
            interaction: Interaction = .none,
            accessibility: Accessibility? = nil,
            inlineImage: InlineImageInfo? = nil
        ) {
            self.text = text
            self.font = font
            self.attributedString = attributedString
            self.alignment = alignment
            self.color = color
            self.interaction = interaction
            self.accessibility = accessibility
            self.inlineImage = inlineImage
        }
        
        // MARK: - Conformance
        
        public func hash(into hasher: inout Hasher) {
            text.hash(into: &hasher)
            font.hash(into: &hasher)
            attributedString.hash(into: &hasher)
            alignment.hash(into: &hasher)
            color.hash(into: &hasher)
            accessibility.hash(into: &hasher)
            inlineImage?.hash(into: &hasher)
        }
        
        public static func == (lhs: TextInfo, rhs: TextInfo) -> Bool {
            return (
                lhs.text == rhs.text &&
                lhs.font == rhs.font &&
                lhs.attributedString == rhs.attributedString &&
                lhs.alignment == rhs.alignment &&
                lhs.color == rhs.color &&
                lhs.accessibility == rhs.accessibility &&
                lhs.inlineImage == rhs.inlineImage
            )
        }
    }
}

public extension SessionListScreenContent.ViewModelType {
    var footerView: some View { EmptyView() }
}
