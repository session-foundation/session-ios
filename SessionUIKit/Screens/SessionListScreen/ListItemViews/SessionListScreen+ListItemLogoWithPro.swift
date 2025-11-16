// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import DifferenceKit

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
    
    public enum State: Equatable, Hashable {
        case loading(message: String)
        case error(message: String)
        case success(description: ThemedAttributedString?)
    }
    
    public struct Info: Equatable, Hashable, Differentiable {
        public let style: ThemeStyle
        public let state: State
        
        public init(style: ThemeStyle, state: State) {
            self.style = style
            self.state = state
        }
    }
    
    let info: Info

    public var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Ellipse()
                    .fill(themeColor: info.style.growingBackgroundColor)
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
                    .foregroundColor(themeColor: info.style.themeColor)
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
                
                SessionProBadge_SwiftUI(size: .medium, themeBackgroundColor: info.style.themeColor)
            }
            .environment(\.layoutDirection, .leftToRight)
            
            if case .success(let description) = info.state, let description {
                AttributedText(description)
                    .font(.Body.baseRegular)
                    .foregroundColor(themeColor: .textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, Values.largeSpacing)
            }
            
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
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .contentShape(Rectangle())
    }
}
