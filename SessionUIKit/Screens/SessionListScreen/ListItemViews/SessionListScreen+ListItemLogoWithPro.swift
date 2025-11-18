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
                    return (blurSize.height - 111) / 2
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
        VStack(spacing: 0) {
            ZStack {
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
