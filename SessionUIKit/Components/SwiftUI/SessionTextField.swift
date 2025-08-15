// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Combine
import UIKit

public struct SessionTextField<ExplanationView>: View where ExplanationView: View {
    @Binding var text: String
    @Binding var error: String?
    @State var lastErroredText: String?
    @State var textThemeColor: ThemeValue = .textPrimary
    @State fileprivate var textChanged: ((String) -> Void)?
    
    @FocusState private var isFirstResponder: Bool
    
    public enum SessionTextFieldType {
        case thin
        case normal
    }
    
    let explanationView: () -> ExplanationView
    let placeholder: String
    let font: Font
    let type: SessionTextFieldType
    let accessibility: Accessibility
    let inputChecker: ((String) -> String?)?
    var isErrorMode: Bool { error?.isEmpty == false }
    
    let height: CGFloat
    let padding: CGFloat
    let cornerRadius: CGFloat
    
    public init(
        _ text: Binding<String>,
        placeholder: String,
        font: Font = .system(size: Values.smallFontSize),
        error: Binding<String?>,
        type: SessionTextFieldType = .normal,
        accessibility: Accessibility = Accessibility(identifier: "SessionTextField"),
        inputChecker: ((String) -> String?)? = nil,
        @ViewBuilder explanationView: @escaping () -> ExplanationView = {
            EmptyView()
        }
    ) {
        self._text = text
        self.placeholder = placeholder
        self.font = font
        self.type = type
        self.accessibility = accessibility
        self._error = error
        self.inputChecker = inputChecker
        self.explanationView = explanationView
        switch self.type {
            case .thin:
                self.height = isIPhone5OrSmaller ? CGFloat(40) : CGFloat(45)
                self.padding = Values.mediumSpacing
                self.cornerRadius = CGFloat(7)
            case .normal:
                self.height = isIPhone5OrSmaller ? CGFloat(48) : CGFloat(80)
                self.padding = Values.largeSpacing
                self.cornerRadius = CGFloat(13)
        }
        UITextView.appearance().backgroundColor = .clear
    }
    
    public var body: some View {
        VStack (
            alignment: .center,
            spacing: Values.smallSpacing
        ) {
            // Text input
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: Values.smallFontSize))
                        .foregroundColor(themeColor: .textSecondary)
                }
                
                if #available(iOS 16.0, *) {
                    TextField(
                        "",
                        text: $text,
                        axis: .vertical
                    )
                    .font(font)
                    .foregroundColor(themeColor: textThemeColor)
                    .accessibility(self.accessibility)
                    .focused($isFirstResponder)
                    
                } else {
                    ZStack {
                        TextEditor(text: $text)
                        .font(font)
                        .foregroundColor(themeColor: textThemeColor)
                        .textViewTransparentScrolling()
                        .accessibility(self.accessibility)
                        .frame(maxHeight: self.height)
                        .padding(.all, -4)
                        .focused($isFirstResponder)
                        
                        // FIXME: This is a workaround for dynamic height of the TextEditor.
                        Text(text.isEmpty ? placeholder : text)
                            .font(font)
                            .opacity(0)
                            .padding(.all, 4)
                            .frame(
                                maxWidth: .infinity,
                                maxHeight: self.height
                            )
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, self.padding)
            .padding(.vertical, Values.smallSpacing)
            .framing(
                maxWidth: .infinity,
                minHeight: self.type == .thin ? self.height : nil,
                height: self.type == .thin ? nil : self.height
            )
            .overlay(
                RoundedRectangle(cornerRadius: self.cornerRadius)
                    .stroke(themeColor: isErrorMode ? .danger : .borderSeparator)
            )
            .contentShape(RoundedRectangle(cornerRadius: self.cornerRadius))
            .onTapGesture { isFirstResponder = !isFirstResponder } // Added hit test to launch keyboard, currently textfield's hit area is too small
            .onChange(of: text) { newText in
                error = inputChecker?(newText)
                textThemeColor = ((newText == lastErroredText || error?.isEmpty == false) ? .danger : .textPrimary)
            }
            .onChange(of: error) { newError in
                if newError != nil {
                    lastErroredText = text
                    textThemeColor = .danger
                }
            }

            // Error message
            switch self.type {
                case .thin:
                    if isErrorMode {
                        Text(error ?? "")
                            .bold()
                            .font(.system(size: Values.smallFontSize))
                            .foregroundColor(themeColor: .danger)
                            .multilineTextAlignment(.center)
                            .accessibility(
                                Accessibility(
                                    identifier: "Error message"
                                )
                            )
                    }
                case .normal:
                    ZStack {
                        if isErrorMode {
                            Text(error ?? "")
                                .bold()
                                .font(.system(size: Values.smallFontSize))
                                .foregroundColor(themeColor: .danger)
                                .multilineTextAlignment(.center)
                                .accessibility(
                                    Accessibility(
                                        identifier: "Error message"
                                    )
                                )
                        } else {
                            explanationView()
                        }
                    }
                    .frame(
                        height: 54,
                        alignment: .top
                    )
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
            SessionTextField($text, placeholder: "Placeholder", error: $error, explanationView:  {})
            SessionTextField($emptyText, placeholder: "Placeholder", error: $emptyError, explanationView:  {})
        }
        
    }
}
