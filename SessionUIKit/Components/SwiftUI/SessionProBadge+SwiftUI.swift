// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

public struct SessionProBadge_SwiftUI: View {
    private let size: SessionProBadge.Size
    private let themeBackgroundColor: ThemeValue
    
    public init(size: SessionProBadge.Size, themeBackgroundColor: ThemeValue = .primary) {
        self.size = size
        self.themeBackgroundColor = themeBackgroundColor
    }
    
    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size.cornerRadius)
                .fill(themeColor: themeBackgroundColor)
            
            Image("session_pro")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size.proFontWidth, height: size.proFontHeight)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }
}
