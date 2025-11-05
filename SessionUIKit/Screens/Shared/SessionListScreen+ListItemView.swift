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

// MARK: - ListItemLogoWithPro

public struct ListItemLogoWithPro: View {
    public enum GlowingBackgroundStyle {
        case base
        case large
        case largeNoPaddings
        
        var blurSize: CGSize {
            switch self {
                case .base:
                    return CGSize(
                        width: UIScreen.main.bounds.width - 2 * Values.mediumSpacing - 20 * 2,
                        height: 111
                    )
                case .large, .largeNoPaddings:
                    return CGSize(
                        width: UIScreen.main.bounds.width - 2 * Values.mediumSpacing,
                        height: UIScreen.main.bounds.width - 2 * Values.mediumSpacing
                    )
            }
        }
        
        var shadowRadius: CGFloat {
            switch self {
                case .base:
                    return 15
                case .large, .largeNoPaddings:
                    return 20
            }
        }
        
        var blurRadius: CGFloat {
            switch self {
                case .base:
                    return 20
                case .large, .largeNoPaddings:
                    return 30
            }
        }
        
        var verticalPaddings: CGFloat {
            switch self {
                case .base, .large:
                    return (blurSize.height - 111) / 2
                case .largeNoPaddings:
                    return 0
            }
        }
        
        var blurMaxHeight: CGFloat {
            switch self {
                case .large:
                    return UIScreen.main.bounds.width - 2 * Values.mediumSpacing
                case .base, .largeNoPaddings:
                    return 111
            }
        }
    }
    
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
    
    public enum State: Equatable, Hashable {
        case loading(message: String)
        case error(message: String)
        case success
    }
    
    public struct Info: Equatable, Hashable, Differentiable {
        public let themeStyle: ThemeStyle
        public let glowingBackgroundStyle: GlowingBackgroundStyle
        public let state: State
        public let description: ThemedAttributedString?
        
        public init(
            themeStyle: ThemeStyle,
            glowingBackgroundStyle: GlowingBackgroundStyle,
            state: State,
            description: ThemedAttributedString? = nil
        ) {
            self.themeStyle = themeStyle
            self.glowingBackgroundStyle = glowingBackgroundStyle
            self.state = state
            self.description = description
        }
    }
    
    let info: Info

    public var body: some View {
        ZStack(alignment: .top) {
            ZStack {
                Ellipse()
                    .fill(themeColor: info.themeStyle.growingBackgroundColor)
                    .frame(
                        width: info.glowingBackgroundStyle.blurSize.width,
                        height: info.glowingBackgroundStyle.blurSize.height
                    )
                    .shadow(radius: info.glowingBackgroundStyle.shadowRadius)
                    .opacity(0.17)
                    .blur(radius: info.glowingBackgroundStyle.blurRadius)
            }
            .frame(maxHeight: info.glowingBackgroundStyle.blurMaxHeight)
            
            VStack(spacing: 0) {
                Image("SessionGreen64")
                    .resizable()
                    .renderingMode(.template)
                    .foregroundColor(themeColor: info.themeStyle.themeColor)
                    .scaledToFit()
                    .frame(width: 100, height: 111)
                
                HStack(spacing: Values.smallSpacing) {
                    Image("SessionHeading")
                        .resizable()
                        .renderingMode(.template)
                        .foregroundColor(themeColor: .textPrimary)
                        .scaledToFit()
                        .frame(width: 131, height: 18)
                    
                    SessionProBadge_SwiftUI(size: .medium, themeBackgroundColor: info.themeStyle.themeColor)
                }
                .padding(.top, Values.mediumSpacing)
                
                if case .error(let message) = info.state {
                    HStack(spacing: Values.verySmallSpacing) {
                        Text(message)
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .font(.Body.baseRegular)
                    .foregroundColor(themeColor: .warning)
                    .padding(.top, Values.mediumSpacing)
                }
                
                if case .loading(let message) = info.state {
                    HStack(spacing: Values.verySmallSpacing) {
                        Text(message)
                        ProgressView()
                            .tint(themeColor: .textPrimary)
                            .controlSize(.regular)
                            .scaleEffect(0.8)
                            .frame(width: 16, height: 16)
                    }
                    .font(.Body.baseRegular)
                    .foregroundColor(themeColor: .textPrimary)
                    .padding(.top, Values.mediumSpacing)
                }
                
                if let description = info.description {
                    AttributedText(description)
                        .font(.Body.baseRegular)
                        .foregroundColor(themeColor: .textPrimary)
                        .multilineTextAlignment(.center)
                        .padding(.top, Values.mediumSpacing)
                        .padding(.bottom, Values.largeSpacing)
                }
            }
            .padding(.vertical, info.glowingBackgroundStyle.verticalPaddings)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .contentShape(Rectangle())
    }
}

// MARK: - ListItemDataMatrix

public struct ListItemDataMatrix: View {
    public struct Info: Equatable, Hashable, Differentiable {
        let leadingAccessory: SessionListScreenContent.ListItemAccessory?
        let title: SessionListScreenContent.TextInfo?
        let trailingAccessory: SessionListScreenContent.ListItemAccessory?
        let tooltipInfo: SessionListScreenContent.TooltipInfo?
        let isLoading: Bool
        
        public init(
            leadingAccessory: SessionListScreenContent.ListItemAccessory? = nil,
            title: SessionListScreenContent.TextInfo? = nil,
            trailingAccessory: SessionListScreenContent.ListItemAccessory? = nil,
            tooltipInfo: SessionListScreenContent.TooltipInfo? = nil,
            isLoading: Bool
        ) {
            self.leadingAccessory = leadingAccessory
            self.title = title
            self.trailingAccessory = trailingAccessory
            self.tooltipInfo = tooltipInfo
            self.isLoading = isLoading
        }
    }
    
    @Binding var isShowingTooltip: Bool
    @Binding var tooltipContent: ThemedAttributedString
    @Binding var tooltipViewId: String
    @Binding var tooltipPosition: ViewPosition
    @Binding var tooltipArrowOffset: CGFloat
    @Binding var suppressUntil: Date
    
    let info: [[Info]]
    
    public var body: some View {
        VStack(spacing: 0) {
            ForEach(info.indices, id: \.self) { rowIndex in
                let row: [Info] = info[rowIndex]
                HStack(spacing: Values.mediumSpacing) {
                    ForEach(row.indices, id: \.self) { columnIndex in
                        let item: Info = row[columnIndex]
                        HStack(spacing: 0) {
                            if item.isLoading {
                                ProgressView()
                                    .padding(.trailing, Values.mediumSpacing)
                            }
                            
                            if let leadingAccessory = item.leadingAccessory, !item.isLoading {
                                leadingAccessory.accessoryView()
                                    .padding(.trailing, Values.mediumSpacing)
                            }
                            
                            if let title = item.title, let text = title.text {
                                Text(text.trimmingCharacters(in: .whitespaces))
                                    .font(title.font)
                                    .multilineTextAlignment(title.alignment)
                                    .foregroundColor(themeColor: title.color)
                                    .accessibility(title.accessibility)
                                    .padding(.trailing, Values.mediumSpacing)
                            }
                            
                            if let trailingAccessory = item.trailingAccessory, !item.isLoading {
                                trailingAccessory.accessoryView()
                                    .padding(.trailing, Values.mediumSpacing)
                            }
                            
                            if let tooltipInfo = item.tooltipInfo, !item.isLoading {
                                Spacer(minLength: 0)
                                
                                Image(systemName: "questionmark.circle")
                                    .font(.Body.baseRegular)
                                    .foregroundColor(themeColor: tooltipInfo.tintColor)
                                    .anchorView(viewId: tooltipInfo.id)
                                    .accessibility(
                                        Accessibility(identifier: "Data Matrix Tooltip")
                                    )
                                    .onTapGesture {
                                        guard Date() >= suppressUntil else { return }
                                        suppressUntil = Date().addingTimeInterval(0.2)
                                        guard tooltipViewId != tooltipInfo.id && !isShowingTooltip else {
                                            withAnimation {
                                                isShowingTooltip = false
                                            }
                                            return
                                        }
                                        tooltipContent = tooltipInfo.content
                                        tooltipPosition = tooltipInfo.position
                                        tooltipViewId = tooltipInfo.id
                                        tooltipArrowOffset = 16
                                        withAnimation {
                                            isShowingTooltip = true
                                        }
                                    }
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
            .contentShape(Rectangle())
        }
    }
}

// MARK: - ListItemButton

struct ListItemButton: View {
    let title: String
    let enabled: Bool
    
    var body: some View {
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
                    .fill(themeColor: enabled ? .sessionButton_primaryFilledBackground : .disabled)
            )
            .padding(.vertical, Values.smallSpacing)
    }
}

