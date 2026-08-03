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
        /// **Note:** `@MainActor` because it's a view - it's only ever evaluated while SwiftUI builds the body, and
        /// isolating it lets an implementation read the view model's main-actor state directly
        @MainActor @ViewBuilder var footerView: FooterView { get }
        
        /// Where `footerView` sits - see `FooterStyle`
        @MainActor var footerStyle: FooterStyle { get }
    }
    
    /// Where a screen's `footerView` is placed
    enum FooterStyle: Equatable {
        /// The footer is the last row of the list and scrolls away with the content, which suits a footer that's
        /// part of the content (eg. the version info at the bottom of the settings screen)
        case inline
        
        /// The footer is pinned above the bottom of the screen with a gradient fading the content out behind it,
        /// which suits an action the user needs to reach at any scroll position (eg. a "Save" button)
        ///
        /// **Note:** This is what the UIKit `SessionTableViewController` did with its `footerButtonInfo` - the
        /// button and the fade were siblings of the table rather than rows within it
        case sticky
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
        
        public typealias ImageAttachment = (
            position: InlineImagePosition,
            cacheKey: UIView.CachedImageKey,
            accessibilityLabel: String?,
            viewGenerator: (() -> UIView)
        )
        
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
    @MainActor var footerView: some View { EmptyView() }
    @MainActor var footerStyle: SessionListScreenContent.FooterStyle { .inline }
}

// MARK: - Convenience

public extension SessionListScreenContent.TextInfo {
    /// Builds a `TextInfo` from a string containing the lightweight markup tags used throughout the app
    /// (`<b>`, `<span>`, `<warn>`, `<br/>`, …)
    ///
    /// The UIKit `SessionCell` ran every subtitle and description through
    /// `ThemedAttributedString(stringWithHTMLTags:font:)` implicitly, so screens written against it pass tagged
    /// strings as plain text and rely on the cell to style them. `TextInfo` takes either plain text **or** an
    /// already-built attributed string and does no conversion of its own, so this does the conversion those
    /// screens expect — without it each one has to hand-roll the same `ThemedAttributedString` at every call site.
    ///
    /// **Note:** The `font` is deliberately applied only to the attributed string (as the base font the tags style
    /// relative to) rather than also being set as a SwiftUI `Font` on the view, since that would override the
    /// per-run fonts the tags produce and a `<b>` run would render un-bolded.
    ///
    /// Returns `nil` for `nil`/empty text so the result can be passed straight to an optional `title`/`description`.
    static func htmlTagged(
        _ text: String?,
        font: UIFont = Fonts.Body.baseRegular,
        alignment: TextAlignment = .leading,
        color: ThemeValue = .textPrimary,
        interaction: Interaction = .none,
        accessibility: Accessibility? = nil
    ) -> SessionListScreenContent.TextInfo? {
        guard let text: String = text, !text.isEmpty else { return nil }
        
        return SessionListScreenContent.TextInfo(
            attributedString: ThemedAttributedString(stringWithHTMLTags: text, font: font),
            alignment: alignment,
            color: color,
            interaction: interaction,
            accessibility: accessibility
        )
    }
}
