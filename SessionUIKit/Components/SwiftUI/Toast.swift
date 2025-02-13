// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Combine
import NaturalLanguage

public struct ToastModifier: ViewModifier {
    @Binding var message: String?
    @State private var workItem: DispatchWorkItem?
    
    public func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(
                ZStack {
                    mainToastView()
                }.animation(.spring(), value: message)
            )
            .onReceive(Just(message)) { value in
                showToast()
            }
    }
  
    @ViewBuilder func mainToastView() -> some View {
        if let message: String = message {
            ToastView(message)
        }
    }
  
    private func showToast() {
        workItem?.cancel()
  
        let task = DispatchWorkItem {
            dismissToast()
        }
  
        workItem = task
        
        let duration: TimeInterval = {
            guard let message: String = message else { return 1.5 }
            
            let tokenizer = NLTokenizer(unit: .word)
            tokenizer.string = message
            let wordCount = tokenizer.tokens(for: message.startIndex..<message.endIndex).count
            return min(1.5 + Double(wordCount - 1) * 0.1 , 5)
        }()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: task)
    }
  
    private func dismissToast() {
        withAnimation {
            message = nil
        }
    
        workItem?.cancel()
        workItem = nil
    }
}

public struct ToastView: View {
    var message: String
    
    static let width: CGFloat = 320
    static let height: CGFloat = 44
    
    public init(_ message: String) {
        self.message = message
    }
    
    public var body: some View {
        VStack(
            spacing: 0
        ) {
            Text(message)
                .font(.system(size: Values.mediumFontSize))
                .foregroundColor(themeColor: .textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Values.largeSpacing)
                .frame(height: Self.height)
                .background(
                    Capsule()
                        .foregroundColor(themeColor: .toast_background)
                )
        }
        .frame(
            maxHeight: .infinity,
            alignment: .bottom
        )
        .padding(.bottom, Values.smallSpacing)
    }
}

struct Toast_Previews: PreviewProvider {
    static var previews: some View {
        ToastView("Test message.")
    }
}
