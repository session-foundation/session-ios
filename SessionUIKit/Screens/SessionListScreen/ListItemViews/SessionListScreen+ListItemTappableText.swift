// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import DifferenceKit

// MARK: - ListItemTappableText

public struct ListItemTappableText: View {
    public struct Info: Equatable, Hashable, Differentiable {
        let text: String
        let font: UIFont
        let themeForegroundColor: ThemeValue
        let imageAttachmentPosition: SessionListScreenContent.TextInfo.InlineImagePosition?
        let imageAttachmentGenerator: (@Sendable () -> (UIImage, String?)?)?
        let onTextTap: (@MainActor @Sendable () -> Void)?
        let onImageTap: (@MainActor @Sendable () -> Void)?
        
        public init(
            text: String,
            font: UIFont,
            themeForegroundColor: ThemeValue = .textPrimary,
            imageAttachmentPosition: SessionListScreenContent.TextInfo.InlineImagePosition? = nil,
            imageAttachmentGenerator: (@Sendable () -> (UIImage, String?)?)? = nil,
            onTextTap: (@MainActor @Sendable () -> Void)? = nil,
            onImageTap: (@MainActor @Sendable () -> Void)? = nil
        ) {
            self.text = text
            self.font = font
            self.themeForegroundColor = themeForegroundColor
            self.imageAttachmentPosition = imageAttachmentPosition
            self.imageAttachmentGenerator = imageAttachmentGenerator
            self.onTextTap = onTextTap
            self.onImageTap = onImageTap
        }
        
        public static func == (lhs: Info, rhs: Info) -> Bool {
            return
                lhs.text == rhs.text &&
                lhs.font == rhs.font &&
                lhs.themeForegroundColor == rhs.themeForegroundColor &&
                lhs.imageAttachmentPosition == rhs.imageAttachmentPosition
        }
        
        public func hash(into hasher: inout Hasher) {
            text.hash(into: &hasher)
            font.hash(into: &hasher)
            themeForegroundColor.hash(into: &hasher)
            imageAttachmentPosition.hash(into: &hasher)
        }
        
        public func makeAttributedString(spacing: String = " ") -> ThemedAttributedString {
            let base = ThemedAttributedString()
            
            if let imageAttachmentPosition, imageAttachmentPosition == .leading, let imageAttachmentGenerator {
                base.append(
                    ThemedAttributedString(
                        imageAttachmentGenerator: imageAttachmentGenerator,
                        referenceFont: font
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
            
            if let imageAttachmentPosition, imageAttachmentPosition == .trailing, let imageAttachmentGenerator {
                base.append(NSAttributedString(string: spacing))
                base.append(
                    ThemedAttributedString(
                        imageAttachmentGenerator: imageAttachmentGenerator,
                        referenceFont: font
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

