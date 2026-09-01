// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import DifferenceKit

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
                        height: 96
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
                    return (blurSize.height - 96) / 2
                case .largeNoPaddings:
                    return 0
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
        
        var glowingBackgroundColor: ThemeValue {
            switch self {
                case .normal: return .primary
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

        /// Identifies the description for a caller which needs to address it, since this component is shared by
        /// screens whose hero copy answers different questions
        public let descriptionAccessibility: Accessibility?

        public init(
            themeStyle: ThemeStyle,
            glowingBackgroundStyle: GlowingBackgroundStyle,
            state: State,
            description: ThemedAttributedString? = nil,
            descriptionAccessibility: Accessibility? = nil
        ) {
            self.themeStyle = themeStyle
            self.glowingBackgroundStyle = glowingBackgroundStyle
            self.state = state
            self.description = description
            self.descriptionAccessibility = descriptionAccessibility
        }
    }
    
    let info: Info

    public var body: some View {
        ZStack(alignment: .top) {
            Ellipse()
                .fill(themeColor: info.themeStyle.glowingBackgroundColor)
                .frame(
                    width: info.glowingBackgroundStyle.blurSize.width,
                    height: info.glowingBackgroundStyle.blurSize.height
                )
                .opacity(0.17)
                .shadow(radius: info.glowingBackgroundStyle.shadowRadius)
                .blur(radius: info.glowingBackgroundStyle.blurRadius)
                .padding(.top, info.glowingBackgroundStyle.blurRadius / 2)
            
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
                .environment(\.layoutDirection, .leftToRight)
                
                /// **Note:** The loading and error banners deliberately share a single accessibility identifier -
                /// they're the same slot, and their messages already distinguish the states
                if case .error(let message) = info.state {
                    HStack(spacing: Values.verySmallSpacing) {
                        Text(message)
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .font(.Body.baseRegular)
                    .foregroundColor(themeColor: .warning)
                    .padding(.top, Values.mediumSpacing)
                    .accessibilityElement(children: .combine)
                    .accessibility(
                        Accessibility(identifier: SessionProUI.AccessibilityIdentifier.statusBanner)
                    )
                }

                if case .loading(let message) = info.state {
                    HStack(spacing: Values.verySmallSpacing) {
                        Text(message)
                        ProgressView()
                            .tint(themeColor: .textPrimary)
                            .controlSize(.regular)
                            .scaleEffect(0.8)
                            .frame(width: 16, height: 16)
                            /// Hidden from accessibility so the combined banner reports the *message* - a
                            /// `ProgressView` contributes its progress as a value, which otherwise wins and the
                            /// banner reads as "1" to both VoiceOver and any test asserting on the state
                            .accessibilityHidden(true)
                    }
                    .font(.Body.baseRegular)
                    .foregroundColor(themeColor: .textPrimary)
                    .padding(.top, Values.mediumSpacing)
                    .accessibilityElement(children: .combine)
                    .accessibility(
                        Accessibility(identifier: SessionProUI.AccessibilityIdentifier.statusBanner)
                    )
                }
                
                /// **Note:** No `accessibilityElement(children: .combine)` here, unlike the banners above: those are
                /// an `HStack` of genuinely separate views, whereas `AttributedText` resolves its runs through
                /// `ThemedText`, which concatenates them into a single `Text`. So this is already one element whose
                /// label is the whole string, and combining would only flatten something that is not split
                if let description = info.description {
                    AttributedText(description)
                        .font(.Body.baseRegular)
                        .foregroundColor(themeColor: .textPrimary)
                        .multilineTextAlignment(.center)
                        .padding(.top, Values.mediumSpacing)
                        .padding(.bottom, Values.largeSpacing)
                        .accessibility(info.descriptionAccessibility)
                }
            }
            .padding(.vertical, info.glowingBackgroundStyle.verticalPaddings)
        }
        .padding(.top, Values.smallSpacing)
        .frame(maxWidth: .infinity, alignment: .top)
        .contentShape(Rectangle())
    }
}
