// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Lucide

public struct TextWithCopyButton: View {
    @Binding private var copied: String?
    
    let content: String
    let font: Font
    let isCopyButtonEnabled: Bool
    
    public init(
        _ content: String,
        font: Font = .system(size: Values.smallFontSize),
        isCopyButtonEnabled: Bool,
        copied: Binding<String?>
    ) {
        self.content = content
        self.font = font
        self.isCopyButtonEnabled = isCopyButtonEnabled
        self._copied = copied
    }
    
    public var body: some View {
        HStack(
            spacing: 0
        ) {
            Text(content)
                .lineLimit(1)
                .truncationMode(.middle)
                .font(font)
                .foregroundColor(themeColor: .textSecondary)
            
            Spacer(minLength: Values.verySmallSpacing)
            
            AttributedText(Lucide.attributedString(icon: .copy, for: .systemFont(ofSize: Values.smallFontSize)))
                .fixedSize()
                .foregroundColor(themeColor: isCopyButtonEnabled ? .textPrimary : .disabled)
        }
        .padding(.horizontal, Values.mediumSpacing)
        .framing(
            maxWidth: .infinity,
            height: Values.largeButtonHeight
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(themeColor: .borderSeparator)
        )
        .onTapGesture {
            guard isCopyButtonEnabled else { return }
            
            UIPasteboard.general.string = content
            copied = "copied".localized()
        }
    }
}
