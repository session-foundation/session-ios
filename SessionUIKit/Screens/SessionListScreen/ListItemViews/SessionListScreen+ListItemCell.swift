// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import DifferenceKit

// MARK: - Truncation Detection Preference Keys

/// Captures the height of the title text rendered at the collapsed line limit
private struct TruncatedTextHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Captures the height of the title text rendered with no line limit
private struct FullTextHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - ListItemCell

public struct ListItemCell: View {
    public struct Info: Equatable, Hashable, Differentiable {
        let leadingAccessory: SessionListScreenContent.ListItemAccessory?
        let title: SessionListScreenContent.TextInfo?
        let description: SessionListScreenContent.TextInfo?
        let trailingAccessory: SessionListScreenContent.ListItemAccessory?
        
        public init(
            leadingAccessory: SessionListScreenContent.ListItemAccessory? = nil,
            title: SessionListScreenContent.TextInfo? = nil,
            description: SessionListScreenContent.TextInfo? = nil,
            trailingAccessory: SessionListScreenContent.ListItemAccessory? = nil
        ) {
            self.leadingAccessory = leadingAccessory
            self.title = title
            self.description = description
            self.trailingAccessory = trailingAccessory
        }
    }
    
    @State private var isExpanded: Bool
    @State private var truncatedTextHeight: CGFloat = 0
    @State private var fullTextHeight: CGFloat = 0
    private var isTruncated: Bool { fullTextHeight > truncatedTextHeight && truncatedTextHeight > 0 }
    
    let info: Info
    let shouldHighlight: Bool
    let height: CGFloat
    let extraTopPadding: CGFloat
    let extraBottomPadding: CGFloat
    let onTap: (() -> Void)?
    
    public init(info: Info, shouldHighlight: Bool, height: CGFloat, extraTopPadding: CGFloat, extraBottomPadding: CGFloat, onTap: (() -> Void)? = nil) {
        self.info = info
        self.shouldHighlight = shouldHighlight
        self.isExpanded = (info.title?.interaction != .expandable)
        self.height = height
        self.extraTopPadding = extraTopPadding
        self.extraBottomPadding = extraBottomPadding
        self.onTap = onTap
    }
    
    @ViewBuilder private func titleTextContent(
        text: String,
        inlineImage: SessionListScreenContent.TextInfo.InlineImageInfo?
    ) -> some View {
        if let inlineImage = inlineImage {
            switch inlineImage.position {
                case .leading:
                    Text("\(Image(uiImage: inlineImage.image)) ") + Text(text)
                case .trailing:
                    Text(text) + Text(" \(Image(uiImage: inlineImage.image))")
            }
        } else {
            Text(text)
        }
    }
    
    public var body: some View {
        Button {
            if info.title?.interaction == .expandable {
                withAnimation { isExpanded.toggle() }
            }
            onTap?()
        } label: {
            HStack(spacing: Values.mediumSpacing) {
                if let leadingAccessory = info.leadingAccessory {
                    leadingAccessory.accessoryView()
                        .padding(.horizontal, leadingAccessory.padding)
                }
                
                if info.title != nil || info.description != nil {
                    VStack(alignment: .center, spacing: 0) {
                        if let title = info.title {
                            HStack(spacing: Values.verySmallSpacing) {
                                if case .trailing = info.title?.alignment { Spacer(minLength: 0) }
                                if case .center = info.title?.alignment { Spacer(minLength: 0) }
                                
                                if let text = title.text {
                                    VStack(spacing: Values.smallSpacing) {
                                        titleTextContent(text: text, inlineImage: title.inlineImage)
                                            .lineLimit(isExpanded ? nil : 2)
                                            .font(title.font)
                                            .multilineTextAlignment(title.alignment)
                                            .foregroundColor(themeColor: title.color)
                                            .accessibility(title.accessibility)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .textSelection(title.interaction == .copy)
                                            /// **Truncation measurement**
                                            ///
                                            /// Two hidden copies are rendered as backgrounds so they share the same
                                            /// proposed width - rach reports its natural height via a preference key.
                                            .background(
                                                ZStack(alignment: .topLeading) {
                                                    titleTextContent(text: text, inlineImage: title.inlineImage)
                                                        .font(title.font)
                                                        .lineLimit(2)
                                                        .fixedSize(horizontal: false, vertical: true)
                                                        .hidden()
                                                        .background(GeometryReader { geo in
                                                            Color.clear.preference(
                                                                key: TruncatedTextHeightKey.self,
                                                                value: geo.size.height
                                                            )
                                                        })
                                                    
                                                    titleTextContent(text: text, inlineImage: title.inlineImage)
                                                        .font(title.font)
                                                        .lineLimit(nil)
                                                        .fixedSize(horizontal: false, vertical: true)
                                                        .hidden()
                                                        .background(GeometryReader { geo in
                                                            Color.clear.preference(
                                                                key: FullTextHeightKey.self,
                                                                value: geo.size.height
                                                            )
                                                        })
                                                }
                                                .hidden()
                                            )
                                            .onPreferenceChange(TruncatedTextHeightKey.self) { truncatedTextHeight = $0 }
                                            .onPreferenceChange(FullTextHeightKey.self) { fullTextHeight = $0 }
                                        
                                        /// Only show the toggle when the text genuinely overflows
                                        if info.title?.interaction == .expandable && isTruncated {
                                            Text(isExpanded ? "viewLess".localized() : "viewMore".localized())
                                                .bold()
                                                .font(title.font)
                                                .foregroundColor(themeColor: .textPrimary)
                                        }
                                    }
                                } else if let attributedString = title.attributedString {
                                    AttributedText(attributedString)
                                        .font(title.font)
                                        .multilineTextAlignment(title.alignment)
                                        .foregroundColor(themeColor: title.color)
                                        .accessibility(title.accessibility)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .textSelection(title.interaction == .copy)
                                }
                                
                                if case .center = info.title?.alignment { Spacer(minLength: 0) }
                                if case .leading = info.title?.alignment { Spacer(minLength: 0) }
                            }
                        }
                        
                        if let description = info.description {
                            HStack(spacing: Values.verySmallSpacing) {
                                if case .trailing = info.description?.alignment { Spacer(minLength: 0) }
                                if case .center = info.description?.alignment { Spacer(minLength: 0) }
                                
                                if let text = description.text {
                                    Text(text)
                                        .font(description.font)
                                        .multilineTextAlignment(description.alignment)
                                        .foregroundColor(themeColor: description.color)
                                        .accessibility(description.accessibility)
                                        .fixedSize(horizontal: false, vertical: true)
                                } else if let attributedString = description.attributedString {
                                    AttributedText(attributedString)
                                        .font(description.font)
                                        .multilineTextAlignment(description.alignment)
                                        .foregroundColor(themeColor: description.color)
                                        .accessibility(description.accessibility)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                
                                if case .center = info.description?.alignment { Spacer(minLength: 0) }
                                if case .leading = info.description?.alignment { Spacer(minLength: 0) }
                            }
                        }
                    }
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                } else {
                    Spacer(minLength: Values.smallSpacing)
                }
                
                if let trailingAccessory = info.trailingAccessory {
                    trailingAccessory.accessoryView()
                        .padding(.horizontal, trailingAccessory.padding)
                }
            }
            .padding(.horizontal, Values.mediumSpacing)
            .contentShape(Rectangle())
            .frame(
                maxWidth: .infinity,
                minHeight: height
            )
            .padding(.vertical, Values.smallSpacing)
            .padding(.top, extraTopPadding)
            .padding(.bottom, extraBottomPadding)
        }
        
        .buttonStyle(HighlightButtonStyle(shouldHighlight: shouldHighlight))
    }
}

struct HighlightButtonStyle: ButtonStyle {
    let shouldHighlight: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .backgroundColor(
                themeColor: (shouldHighlight && configuration.isPressed) ? .sessionButton_highlight : .clear
            )
    }
}
