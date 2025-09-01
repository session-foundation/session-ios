// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

extension SessionListScreen {
    struct ListItemCell: View {
        let info: SessionListScreenContent.CellInfo
        
        var body: some View {
            HStack(spacing: 0) {
                
            }
        }
    }
    
    struct ListItemLogWithPro: View {
        var body: some View {
            VStack(spacing: 0) {
                ZStack {
                    Ellipse()
                        .fill(themeColor: .settings_glowingBackground)
                        .framing(
                            maxWidth: .infinity,
                            height: 133
                        )
                        .shadow(radius: 15)
                        .opacity(0.15)
                        .blur(radius: 20)
                    
                    Image("SessionGreen64")
                        .resizable()
                        .renderingMode(.template)
                        .foregroundColor(themeColor: .primary)
                        .scaledToFit()
                        .frame(width: 100, height: 111)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                
                HStack(spacing: Values.smallSpacing) {
                    Image("SessionHeading")
                        .resizable()
                        .renderingMode(.template)
                        .foregroundColor(themeColor: .textPrimary)
                        .scaledToFit()
                        .frame(width: 131, height: 18)
                    
                    SessionProBadge_SwiftUI(size: .medium)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
    
    struct ListItemDataMatrixInfo: View {
        let info: [[SessionListScreenContent.DataMatrixInfo]]
        
        var body: some View {
            VStack(spacing: 0) {
                
            }
        }
    }
}
