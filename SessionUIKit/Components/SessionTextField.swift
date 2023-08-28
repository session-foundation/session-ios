// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Combine

public struct SessionTextField: View {
    @Binding var text: String
    @Binding var error: String?
    @State var previousError: String = ""
    
    let placeholder: String
    var textThemeColor: ThemeValue {
        (error?.isEmpty == false) ? .danger : .textPrimary
    }
    var isErrorMode: Bool {
        guard previousError.isEmpty else { return true }
        if error?.isEmpty == false { return true }
        return false
    }
    
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
                        .font(.system(size: Values.smallFontSize))
                        .foregroundColor(themeColor: isErrorMode ? .danger : .textSecondary)
                }
                
                SwiftUI.TextField(
                    "",
                    text: $text.onChange{ value in
                        if error?.isEmpty == false && text != value {
                            previousError = error!
                            error = nil
                        }
                    }
                )
                .font(.system(size: Values.smallFontSize))
                .foregroundColor(themeColor: textThemeColor)
            }
            .padding(.horizontal, Values.largeSpacing)
            .frame(maxWidth: .infinity)
            .frame(height: Self.height)
            .overlay(
                RoundedRectangle(
                    cornerSize: CGSize(
                        width: Self.cornerRadius,
                        height: Self.cornerRadius
                    )
                )
                .stroke(themeColor: isErrorMode ? .danger : .borderSeparator)
            )
            
            ZStack {
                Text(error ?? previousError)
                    .bold()
                    .font(.system(size: Values.smallFontSize))
                    .foregroundColor(themeColor: .danger)
                    .multilineTextAlignment(.center)
            }
            .frame(
                height: 50,
                alignment: .top
            )
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
