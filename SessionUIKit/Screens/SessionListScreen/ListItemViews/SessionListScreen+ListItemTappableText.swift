// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import DifferenceKit

// MARK: - ListItemTappableText

public struct ListItemTappableText: View {
    public struct Info: Equatable, Hashable, Differentiable {
        let text: String
        let font: UIFont
        let themeForegroundColor: ThemeValue
        let imageAttachment: SessionListScreenContent.TextInfo.ImageAttachment?
        let onTextTap: (@MainActor @Sendable () -> Void)?
        let onImageTap: (@MainActor @Sendable () -> Void)?
        
        public init(
            text: String,
            font: UIFont,
            themeForegroundColor: ThemeValue = .textPrimary,
            imageAttachment: SessionListScreenContent.TextInfo.ImageAttachment? = nil,
            onTextTap: (@MainActor @Sendable () -> Void)? = nil,
            onImageTap: (@MainActor @Sendable () -> Void)? = nil
        ) {
            self.text = text
            self.font = font
            self.themeForegroundColor = themeForegroundColor
            self.imageAttachment = imageAttachment
            self.onTextTap = onTextTap
            self.onImageTap = onImageTap
        }
        
        public static func == (lhs: Info, rhs: Info) -> Bool {
            return
                lhs.text == rhs.text &&
                lhs.font == rhs.font &&
                lhs.themeForegroundColor == rhs.themeForegroundColor &&
                lhs.imageAttachment?.position == rhs.imageAttachment?.position &&
                lhs.imageAttachment?.cacheKey == rhs.imageAttachment?.cacheKey &&
                lhs.imageAttachment?.accessibilityLabel == rhs.imageAttachment?.accessibilityLabel
        }
        
        public func hash(into hasher: inout Hasher) {
            text.hash(into: &hasher)
            font.hash(into: &hasher)
            themeForegroundColor.hash(into: &hasher)
            imageAttachment?.position.hash(into: &hasher)
            imageAttachment?.cacheKey.hash(into: &hasher)
            imageAttachment?.accessibilityLabel.hash(into: &hasher)
        }
        
        @MainActor public func makeAttributedString(spacing: String = " ") -> ThemedAttributedString {
            let base = ThemedAttributedString()
            
            if
                let imageAttachment: SessionListScreenContent.TextInfo.ImageAttachment = imageAttachment,
                imageAttachment.position == .leading
            {
                base.append(
                    ThemedAttributedString(
                        image: UIView.image(
                            for: imageAttachment.cacheKey,
                            generator: imageAttachment.viewGenerator
                        ),
                        accessibilityLabel: imageAttachment.accessibilityLabel,
                        font: font
                    )
                )
                base.append(NSAttributedString(string: spacing))
            }
            
            base.append(
                ThemedAttributedString(
                    string: text,
                    attributes: [
                        .font: font as Any,
                        .themeForegroundColor: themeForegroundColor
                    ]
                )
            )
            
            if
                let imageAttachment: SessionListScreenContent.TextInfo.ImageAttachment = imageAttachment,
                imageAttachment.position == .trailing
            {
                base.append(NSAttributedString(string: spacing))
                base.append(
                    ThemedAttributedString(
                        image: UIView.image(
                            for: imageAttachment.cacheKey,
                            generator: imageAttachment.viewGenerator
                        ),
                        accessibilityLabel: imageAttachment.accessibilityLabel,
                        font: font
                    )
                )
            }
            
            return base
        }
    }
    
    let info: Info
    let height: CGFloat
    
    public var body: some View {
        AttributedLabel(
            info.makeAttributedString(),
            alignment: .center,
            maxWidth: (UIScreen.main.bounds.width - Values.mediumSpacing * 2 - Values.largeSpacing * 2),
            onTextTap: info.onTextTap,
            onImageTap: info.onImageTap
        )
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, Values.mediumSpacing)
    }
}

