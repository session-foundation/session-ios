// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import NVActivityIndicatorView
import SessionUIKit
import SessionMessagingKit

public struct LinkPreviewView_SwiftUI: View {
    private static let loaderSize: CGFloat = 24
    private static let cancelButtonSize: CGFloat = 45
    
    private let maxWidth: CGFloat
    private let onCancel: (() -> ())?
    
    public init(maxWidth: CGFloat, onCancel: (() -> ())? = nil) {
        self.maxWidth = maxWidth
        self.onCancel = onCancel
    }
    
    public var body: some View {
        VStack(
            alignment: .leading,
            spacing: 0
        ) {
            HStack(
                alignment: .center,
                spacing: 0
            ) {
                
                
            }
            
            Text(/*@START_MENU_TOKEN@*/"Hello, World!"/*@END_MENU_TOKEN@*/)
        }
    }
}

struct LinkPreviewView_SwiftUI_Previews: PreviewProvider {
    static var previews: some View {
        LinkPreviewView_SwiftUI(
            maxWidth: 200,
            onCancel: nil
        )
    }
}
