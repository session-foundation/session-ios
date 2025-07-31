// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

public struct Seperator_SwiftUI: View {
    
    public let title: String
    
    public var body: some View {
        HStack(spacing: 0) {
            Line(color: .textSecondary, lineWidth: Values.separatorThickness)
            
            Text(title)
                .font(.Body.smallRegular)
                .foregroundColor(themeColor: .textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .overlay(
                    Capsule()
                        .stroke(themeColor: .textSecondary)
                )
            
            Line(color: .textSecondary, lineWidth: Values.separatorThickness)
        }
    }
}
