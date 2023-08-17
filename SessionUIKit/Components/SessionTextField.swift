// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

public struct SessionTextField: View {
    @Binding var text: String
    let placeholder: String
    
    static let height: CGFloat = isIPhone5OrSmaller ? CGFloat(48) : CGFloat(80)
    static let cornerRadius: CGFloat = 13
    
    public init(_ text: Binding<String>, placeholder: String) {
        self._text = text
        self.placeholder = placeholder
    }
    
    public var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: Values.mediumFontSize))
                    .foregroundColor(themeColor: .textSecondary)
            }
            
            SwiftUI.TextField(
                "",
                text: $text
            )
            .font(.system(size: Values.mediumFontSize))
            .foregroundColor(themeColor: .textPrimary)
        }
        .padding(.horizontal, Values.largeSpacing)
        .frame(
            maxWidth: .infinity,
            maxHeight: Self.height
        )
        .overlay(
            RoundedRectangle(
                cornerSize: CGSize(
                    width: Self.cornerRadius,
                    height: Self.cornerRadius
                )
            )
            .stroke(themeColor: .borderSeparator)
        )
    }
}

struct SessionTextField_Previews: PreviewProvider {
    @State static var text: String = ""
    static var previews: some View {
        SessionTextField($text, placeholder: "Placeholder")
    }
}
