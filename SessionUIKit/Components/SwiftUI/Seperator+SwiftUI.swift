// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

public struct Seperator_SwiftUI: View {
    
    public let title: String
    public let font: Font
    
    public init(title: String, font: Font = .Body.smallRegular) {
        self.title = title
        self.font = font
    }
    
    public var body: some View {
        HStack(spacing: 0) {
            Line(color: .textSecondary, lineWidth: Values.separatorThickness)
            
            Text(title)
                .font(font)
                .foregroundColor(themeColor: .textSecondary)
                .fixedSize()
                .padding(.horizontal, 30)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .stroke(themeColor: .textSecondary, lineWidth: Values.separatorThickness)
                )
            
            Line(color: .textSecondary, lineWidth: Values.separatorThickness)
        }
    }
}
