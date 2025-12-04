// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import DifferenceKit

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
    
    let info: Info
    let height: CGFloat
    
    public var body: some View {
        HStack(spacing: Values.mediumSpacing) {
            if let leadingAccessory = info.leadingAccessory {
                leadingAccessory.accessoryView()
                    .padding(.horizontal, leadingAccessory.padding)
            }
            
            VStack(alignment: .center, spacing: 0) {
                if let title = info.title {
                    HStack(spacing: Values.verySmallSpacing) {
                        if case .trailing = info.title?.alignment { Spacer(minLength: 0) }
                        if case .center = info.title?.alignment { Spacer(minLength: 0) }
                        
                        if case .proBadgeLeading(let themeBackgroundColor) = title.accessory  {
                            SessionProBadge_SwiftUI(size: .mini, themeBackgroundColor: themeBackgroundColor)
                        }
                        
                        if let text = title.text {
                            ZStack {
                                if let trailingImage = title.trailingImage {
                                    (Text(text) + Text(" \(Image(uiImage: trailingImage))"))
                                } else {
                                    Text(text)
                                }
                            }
                            .font(title.font)
                            .multilineTextAlignment(title.alignment)
                            .foregroundColor(themeColor: title.color)
                            .accessibility(title.accessibility)
                            .fixedSize(horizontal: false, vertical: true)
                        } else if let attributedString = title.attributedString {
                            AttributedText(attributedString)
                                .font(title.font)
                                .multilineTextAlignment(title.alignment)
                                .foregroundColor(themeColor: title.color)
                                .accessibility(title.accessibility)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        
                        if case .proBadgeTrailing(let themeBackgroundColor) = title.accessory  {
                            SessionProBadge_SwiftUI(size: .mini, themeBackgroundColor: themeBackgroundColor)
                        }
                        
                        if case .center = info.title?.alignment { Spacer(minLength: 0) }
                        if case .leading = info.title?.alignment { Spacer(minLength: 0) }
                    }
                }
                
                if let description = info.description {
                    HStack(spacing: Values.verySmallSpacing) {
                        if case .trailing = info.description?.alignment { Spacer(minLength: 0) }
                        if case .center = info.description?.alignment { Spacer(minLength: 0) }
                        
                        if case .proBadgeLeading(let themeBackgroundColor) = description.accessory {
                            SessionProBadge_SwiftUI(size: .mini, themeBackgroundColor: themeBackgroundColor)
                        }
                        
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
                        
                        if case .proBadgeTrailing(let themeBackgroundColor) = description.accessory {
                            SessionProBadge_SwiftUI(size: .mini, themeBackgroundColor: themeBackgroundColor)
                        }
                        
                        if case .center = info.description?.alignment { Spacer(minLength: 0) }
                        if case .leading = info.description?.alignment { Spacer(minLength: 0) }
                    }
                }
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .leading
            )
            
            if let trailingAccessory = info.trailingAccessory {
                trailingAccessory.accessoryView()
                    .padding(.horizontal, trailingAccessory.padding)
            }
        }
        .padding(.horizontal, Values.mediumSpacing)
        .frame(
            maxWidth: .infinity,
            minHeight: height,
            alignment: .leading
        )
        .contentShape(Rectangle())
    }
}
