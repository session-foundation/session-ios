// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Combine
import UIKit

public struct SessionTextField<ExplanationView>: View where ExplanationView: View {
    @Binding var text: String
    @Binding var error: String?
    @State var previousError: String = ""
    
    let explanationView: () -> ExplanationView
    let placeholder: String
    var textThemeColor: ThemeValue {
        (error?.isEmpty == false) ? .danger : .textPrimary
    }
    var isErrorMode: Bool {
        guard previousError.isEmpty else { return true }
        if error?.isEmpty == false { return true }
        return false
    }
    
    let height: CGFloat = isIPhone5OrSmaller ? CGFloat(48) : CGFloat(80)
    let cornerRadius: CGFloat = 13
    
    public init(_ text: Binding<String>, placeholder: String, error: Binding<String?>, @ViewBuilder explanationView: @escaping () -> ExplanationView) {
        self._text = text
        self.placeholder = placeholder
        self._error = error
        self.explanationView = explanationView
        UITextView.appearance().backgroundColor = .clear
    }
    
    public var body: some View {
        VStack (
            alignment: .center,
            spacing: Values.smallSpacing
        ) {
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: Values.smallFontSize))
                        .foregroundColor(themeColor: isErrorMode ? .danger : .textSecondary)
                }
                
                if #available(iOS 16.0, *) {
                    SwiftUI.TextField(
                        "",
                        text: $text.onChange{ value in
                            if error?.isEmpty == false && text != value {
                                previousError = error!
                                error = nil
                            }
                        },
                        axis: .vertical
                    )
                    .font(.system(size: Values.smallFontSize))
                    .foregroundColor(themeColor: textThemeColor)
                } else if #available(iOS 14.0, *) {
                    ZStack {
                        TextEditor(
                            text: $text.onChange{ value in
                                if error?.isEmpty == false && text != value {
                                    previousError = error!
                                    error = nil
                                }
                            }
                        )
                        .font(.system(size: Values.smallFontSize))
                        .foregroundColor(themeColor: textThemeColor)
                        .transparentScrolling()
                        .frame(maxHeight: self.height)
                        .padding(.all, -4)
                        
                        // FIXME: This is a workaround for dynamic height of the TextEditor.
                        Text(text.isEmpty ? placeholder : text)
                            .font(.system(size: Values.smallFontSize))
                            .opacity(0)
                            .padding(.all, 4)
                            .frame(
                                maxWidth: .infinity,
                                maxHeight: self.height
                            )
                    }
                    .fixedSize(horizontal: false, vertical: true)
                } else {
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
            }
            .padding(.horizontal, Values.largeSpacing)
            .frame(maxWidth: .infinity)
            .frame(height: self.height)
            .overlay(
                RoundedRectangle(
                    cornerSize: CGSize(
                        width: self.cornerRadius,
                        height: self.cornerRadius
                    )
                )
                .stroke(themeColor: isErrorMode ? .danger : .borderSeparator)
            )
            
            if isErrorMode {
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
            } else {
                explanationView()
            }
        }
    }
}

struct SessionTextField_Previews: PreviewProvider {
    @State static var text: String = "test"
    @State static var error: String? = "test error"
    @State static var emptyText: String = ""
    @State static var emptyError: String? = nil
    static var previews: some View {
        VStack {
            SessionTextField($text, placeholder: "Placeholder", error: $error) {}
            SessionTextField($emptyText, placeholder: "Placeholder", error: $emptyError) {}
        }
        
    }
}
