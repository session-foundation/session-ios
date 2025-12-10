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
            }
            
            VStack(alignment: .leading, spacing: 0) {
                if let title = info.title {
                    HStack(spacing: Values.verySmallSpacing) {
                        if case .proBadgeLeading(let themeBackgroundColor) = title.accessory  {
                            SessionProBadge_SwiftUI(size: .mini, themeBackgroundColor: themeBackgroundColor)
                        }
                        
                        if let text = title.text {
                            Text(text)
                                .font(title.font)
                                .multilineTextAlignment(title.alignment)
                                .foregroundColor(themeColor: title.color)
                                .accessibility(title.accessibility)
                                .fixedSize()
                        } else if let attributedString = title.attributedString {
                            AttributedText(attributedString)
                                .font(title.font)
                                .multilineTextAlignment(title.alignment)
                                .foregroundColor(themeColor: title.color)
                                .accessibility(title.accessibility)
                                .fixedSize()
                        }
                        
                        if case .proBadgeTrailing(let themeBackgroundColor) = title.accessory  {
                            SessionProBadge_SwiftUI(size: .mini, themeBackgroundColor: themeBackgroundColor)
                        }
                    }
                }
                
                if let description = info.description {
                    HStack(spacing: Values.verySmallSpacing) {
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
                    }
                }
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .leading
            )
            
            if let trailingAccessory = info.trailingAccessory {
                Spacer(minLength: 0)
                trailingAccessory.accessoryView()
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
