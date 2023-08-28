// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

public struct Toast: View {
    @State var dismiss: Bool = false
    
    let message: String
    
    static let width: CGFloat = 320
    static let height: CGFloat = 44
    
    public init(_ message: String) {
        self.message = message
    }
    
    public var body: some View {
        VStack {
            Spacer()
            
            if !dismiss {
                ZStack {
                    Capsule()
                        .foregroundColor(themeColor: .toast_background)
                    
                    Text(message)
                        .font(.system(size: Values.verySmallFontSize))
                        .foregroundColor(themeColor: .textPrimary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, Values.mediumSpacing)
                }
                .frame(
                    width: Self.width,
                    height: Self.height
                )
                .padding(.bottom, Values.smallSpacing)
            }
        }
        .onAppear {
            Timer.scheduledTimerOnMainThread(withTimeInterval: 5) { _ in
                withAnimation(.easeOut(duration: 0.5)) {
                    dismiss.toggle()
                }
            }
        }
    }
}

struct Toast_Previews: PreviewProvider {
    static var previews: some View {
        Toast("This QR code does not contain a Recovery Password.")
    }
}
