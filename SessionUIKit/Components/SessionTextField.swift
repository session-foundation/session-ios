// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

public struct SessionTextField: View {
    @Binding var text: String
    @Binding var error: String?
    
    let placeholder: String
    
    static let height: CGFloat = isIPhone5OrSmaller ? CGFloat(48) : CGFloat(80)
    static let cornerRadius: CGFloat = 13
    
    public init(_ text: Binding<String>, placeholder: String, error: Binding<String?>) {
        self._text = text
        self.placeholder = placeholder
        self._error = error
    }
    
    public var body: some View {
        VStack (
            alignment: .center,
            spacing: Values.smallSpacing
        ) {
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
                .foregroundColor(themeColor: (error?.isEmpty == false) ? .danger : .textPrimary)
                .onReceive(text.publisher, perform: { _ in
                    error = nil
                })
                
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
                .stroke(themeColor: (error?.isEmpty == false) ? .danger : .borderSeparator)
            )
            
            Text(error ?? " ")
                .bold()
                .font(.system(size: Values.mediumFontSize))
                .foregroundColor(themeColor: .danger)
                .multilineTextAlignment(.center)
        }
    }
}

struct SessionTextField_Previews: PreviewProvider {
    @State static var text: String = "test"
    @State static var error: String? = "test error"
    static var previews: some View {
        SessionTextField($text, placeholder: "Placeholder", error: $error)
    }
}
