// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

public class SessionButtonViewModel: ObservableObject {
    public enum Style {
        case bordered
        case borderless
        case destructive
        case destructiveBorderless
        case filled
        
        var themeTitleColor: ThemeValue {
            switch self {
                case .bordered, .borderless: return .sessionButton_text
                case .destructive, .destructiveBorderless: return .sessionButton_destructiveText
                case .filled: return .sessionButton_filledText
            }
        }
        
        var themeTitleHightlightColor: ThemeValue {
            switch self {
                case .borderless: return .highlighted(.sessionButton_text)
                case .destructiveBorderless: return .highlighted(.sessionButton_destructiveText)
                case .bordered, .destructive, .filled: return themeTitleColor
            }
        }
        
        var themeBackgroundColor: ThemeValue {
            switch self {
                case .bordered: return .sessionButton_background
                case .destructive: return .sessionButton_destructiveBackground
                case .borderless, .destructiveBorderless: return .clear
                case .filled: return .sessionButton_filledBackground
            }
        }
        
        var themeBackgroundHightlightColor: ThemeValue {
            switch self {
                case .bordered: return .sessionButton_highlight
                case .destructive: return .sessionButton_destructiveHighlight
                case .borderless, .destructiveBorderless: return themeBackgroundColor
                case .filled: return .sessionButton_filledHighlight
            }
        }
        
        var themeBorderColor: ThemeValue {
            switch self {
                case .bordered: return .sessionButton_border
                case .destructive: return .sessionButton_destructiveBorder
                case .filled, .borderless, .destructiveBorderless: return .clear
            }
        }
        
        var borderWidth: CGFloat {
            switch self {
                case .borderless, .destructiveBorderless: return 0
                default: return 1
            }
        }
    }
    
    public enum Size {
        case small
        case medium
        case large
        
        var height: CGFloat {
            switch self {
                case .small: return Values.smallButtonHeight
                case .medium: return Values.mediumButtonHeight
                case .large: return Values.largeButtonHeight
            }
        }
        
        var font: Font {
            switch self {
                case .small: return .Headings.H9
                case .medium, .large: return .Headings.H8
            }
        }
    }
    
    @Published public var title: String
    public var isEnabled: Bool = true
    let style: Style
    let size: Size
    let accessibility: Accessibility?
    let action: (SessionButtonViewModel) -> Void
    
    public init(title: String, style: Style, size: Size = .medium, accessibility: Accessibility? = nil, action: @escaping (SessionButtonViewModel) -> Void) {
        self.title = title
        self.style = style
        self.size = size
        self.accessibility = accessibility
        self.action = action
    }
}

struct SessionButtonStyle: ButtonStyle {
    let style: SessionButtonViewModel.Style
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(
                themeColor: (
                    configuration.isPressed ?
                        style.themeTitleHightlightColor :
                        style.themeTitleColor
                )
            )
            .backgroundColor(
                themeColor: (
                    configuration.isPressed ?
                        style.themeBackgroundHightlightColor :
                        style.themeBackgroundColor
                )
            )
            .overlay(
                Capsule()
                    .stroke(
                        themeColor: style.themeBorderColor,
                        lineWidth: style.borderWidth
                    )
            )
    }
}

public struct SessionButton_SwiftUI: View {
    @StateObject private var viewModel: SessionButtonViewModel
    
    public init(_ viewModel: SessionButtonViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }
    
    public var body: some View {
        Button {
            if viewModel.isEnabled {
                viewModel.action(viewModel)
            }
        } label: {
            Text(viewModel.title)
                .font(viewModel.size.font)
                .framing(
                    maxWidth: .infinity,
                    height: viewModel.size.height
                )
        }
        .accessibility(viewModel.accessibility)
        .buttonStyle(SessionButtonStyle(style: viewModel.style))
    }
}
