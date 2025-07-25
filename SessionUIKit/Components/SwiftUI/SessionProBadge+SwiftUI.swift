// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

public struct SessionProBadge_SwiftUI: View {
    private let size: SessionProBadge.Size
    
    public init(size: SessionProBadge.Size) {
        self.size = size
    }
    
    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size.cornerRadius)
                .fill(themeColor: .primary)
            
            Image("session_pro")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size.proFontWidth, height: size.proFontHeight)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }
}
