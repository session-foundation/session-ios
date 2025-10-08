// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

// MARK: - ListItemCell

struct ListItemCell: View {
    let info: SessionListScreenContent.CellInfo
    let height: CGFloat
    
    var body: some View {
        HStack(spacing: Values.mediumSpacing) {
            if let leadingAccessory = info.leadingAccessory {
                leadingAccessory.accessoryView()
            }
            
            VStack(alignment: .leading, spacing: 0) {
                if let title = info.title {
                    HStack(spacing: Values.verySmallSpacing) {
                        if title.accessory == .proBadgeLeading {
                            SessionProBadge_SwiftUI(size: .mini)
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
                        
                        if title.accessory == .proBadgeTrailing {
                            SessionProBadge_SwiftUI(size: .mini)
                        }
                    }
                }
                
                if let description = info.description {
                    HStack(spacing: Values.verySmallSpacing) {
                        if description.accessory == .proBadgeLeading {
                            SessionProBadge_SwiftUI(size: .mini)
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
                        
                        if description.accessory == .proBadgeTrailing {
                            SessionProBadge_SwiftUI(size: .mini)
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
    }
}

// MARK: - ListItemLogoWithPro

public struct ListItemLogoWithPro: View {
    public enum ThemeStyle {
        case normal
        case disabled
        
        var themeColor: ThemeValue {
            switch self {
                case .normal: return .primary
                case .disabled: return .disabled
            }
        }
        
        var growingBackgroundColor: ThemeValue {
            switch self {
                case .normal: return .settings_glowingBackground
                case .disabled: return .disabled
            }
        }
    }
    
    let style: ThemeStyle
    let description: ThemedAttributedString?
    
    public init(style: ThemeStyle = .normal, description: ThemedAttributedString?) {
        self.style = style
        self.description = description
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Ellipse()
                    .fill(themeColor: style.growingBackgroundColor)
                    .frame(
                        width: UIScreen.main.bounds.width - 2 * Values.mediumSpacing - 20 * 2,
                        height: 111
                    )
                    .shadow(radius: 15)
                    .opacity(0.15)
                    .blur(radius: 20)
                
                Image("SessionGreen64")
                    .resizable()
                    .renderingMode(.template)
                    .foregroundColor(themeColor: style.themeColor)
                    .scaledToFit()
                    .frame(width: 100, height: 111)
            }
            .framing(
                maxWidth: .infinity,
                height: 133,
                alignment: .center
            )
            
            HStack(spacing: Values.smallSpacing) {
                Image("SessionHeading")
                    .resizable()
                    .renderingMode(.template)
                    .foregroundColor(themeColor: .textPrimary)
                    .scaledToFit()
                    .frame(width: 131, height: 18)
                
                SessionProBadge_SwiftUI(size: .medium, themeBackgroundColor: style.themeColor)
            }
            
            if let description {
                AttributedText(description)
                    .font(.Body.baseRegular)
                    .foregroundColor(themeColor: .textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, Values.largeSpacing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - ListItemDataMatrix

struct ListItemDataMatrix: View {
    let info: [[SessionListScreenContent.DataMatrixInfo]]
    
    var body: some View {
        VStack(spacing: 0) {
            ForEach(info.indices, id: \.self) { rowIndex in
                let row: [SessionListScreenContent.DataMatrixInfo] = info[rowIndex]
                HStack(spacing: Values.mediumSpacing) {
                    ForEach(row.indices, id: \.self) { columnIndex in
                        let item: SessionListScreenContent.DataMatrixInfo = row[columnIndex]
                        HStack(spacing: Values.mediumSpacing) {
                            if let leadingAccessory = item.leadingAccessory {
                                leadingAccessory.accessoryView()
                            }
                            
                            if let title = item.title, let text = title.text {
                                Text(text)
                                    .font(title.font)
                                    .multilineTextAlignment(title.alignment)
                                    .foregroundColor(themeColor: title.color)
                                    .accessibility(title.accessibility)
                            }
                            
                            if let trailingAccessory = item.trailingAccessory {
                                trailingAccessory.accessoryView()
                            }
                        }
                        .frame(
                            maxWidth: .infinity,
                            alignment: .leading
                        )
                    }
                }
                .padding(.vertical, Values.smallSpacing)
            }
            .padding(.horizontal, Values.mediumSpacing)
            .padding(.vertical, Values.smallSpacing)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - ListItemButton

struct ListItemButton: View {
    let title: String
    let action: (() -> Void)?
    
    var body: some View {
        Button {
            action?()
        } label: {
            Text(title)
                .font(.Body.largeRegular)
                .foregroundColor(themeColor: .sessionButton_primaryFilledText)
                .framing(
                    maxWidth: .infinity,
                    height: 50,
                    alignment: .center
                )
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(themeColor: .sessionButton_primaryFilledBackground)
                )
                .padding(.vertical, Values.smallSpacing)
        }
    }
}
