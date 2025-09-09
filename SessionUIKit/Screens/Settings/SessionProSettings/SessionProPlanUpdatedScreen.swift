// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Lucide

public struct SessionProPlanUpdatedScreen: View {
    @EnvironmentObject var host: HostWrapper
    let expiredOn: Date
    var blurSize: CGFloat { UIScreen.main.bounds.width - 2 * Values.mediumSpacing }
    
    public var body: some View {
        ZStack(alignment: .top) {
            Ellipse()
                .fill(themeColor: .settings_glowingBackground)
                .frame(width: blurSize, height: blurSize)
                .shadow(radius: 20)
                .opacity(0.17)
                .blur(radius: 30)
            
            VStack(spacing: Values.mediumSpacing) {
                Image("SessionGreen64")
                    .resizable()
                    .renderingMode(.template)
                    .foregroundColor(themeColor: .primary)
                    .scaledToFit()
                    .frame(width: 100, height: 111)
                
                HStack(spacing: Values.smallSpacing) {
                    Image("SessionHeading")
                        .resizable()
                        .renderingMode(.template)
                        .foregroundColor(themeColor: .textPrimary)
                        .scaledToFit()
                        .frame(width: 180, height: 24)
                    
                    SessionProBadge_SwiftUI(size: .large)
                }
                .padding(.bottom, Values.smallSpacing)
                
                Text("proAllSet".localized())
                    .font(.Headings.H6)
                    .foregroundColor(themeColor: .textPrimary)
                
                AttributedText(
                    "proAllSetDescription"
                        .put(key: "app_pro", value: Constants.app_pro)
                        .put(key: "pro", value: Constants.pro)
                        .put(key: "date", value: expiredOn.formatted("MMM dd, yyyy"))
                        .localizedFormatted(Fonts.Body.baseRegular)
                )
                .font(.Body.baseRegular)
                .foregroundColor(themeColor: .textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Values.mediumSpacing)
                
                Button {
                    
                } label: {
                    Text("theReturn".localized())
                        .font(.Body.largeRegular)
                        .foregroundColor(themeColor: .sessionButton_primaryFilledText)
                        .framing(
                            maxWidth: .infinity,
                            height: 50,
                            alignment: .center
                        )
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(themeColor: .sessionButton_primaryFilledBackground)
                        )
                }
                .padding(.vertical, Values.smallSpacing)
            }
            .padding(.horizontal, Values.mediumSpacing)
            .padding(.vertical, (blurSize - 111) / 2)
        }
    }
}
