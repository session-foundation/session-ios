// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Lucide
import Combine

public struct MutipleLinksModal: View {
    @EnvironmentObject var host: HostWrapper
    
    private var links: [String]
    let dismissType: Modal.DismissType
    let openURL: ((URL) -> Void)
    
    public init(
        links: [String],
        dismissType: Modal.DismissType = .recursive,
        openURL: @escaping ((URL) -> Void)
    ) {
        self.links = links
        self.dismissType = dismissType
        self.openURL = openURL
    }
    
    public var body: some View {
        Modal_SwiftUI(
            host: host,
            dismissType: dismissType,
            afterClosed: nil
        ) { close in
            ZStack(alignment: .topTrailing) {
                // Closed button
                Button {
                    close(nil)
                } label: {
                    AttributedText(Lucide.Icon.x.attributedString(size: 20))
                        .font(.system(size: 20))
                        .foregroundColor(themeColor: .textPrimary)
                }
                .frame(width: 24, height: 24)
                
                VStack(spacing: Values.mediumSpacing) {
                    Text("urlOpen".localized())
                        .font(.Headings.H7)
                        .foregroundColor(themeColor: .textPrimary)
                    
                    Text("urlOpenDescriptionAlternative".localized())
                        .font(.Body.largeRegular)
                        .foregroundColor(themeColor: .textPrimary)
                    
                    VStack(spacing: Values.mediumSpacing) {
                        ForEach(links.indices, id: \.self) { index in
                            HStack(spacing: 0) {
                                Text(links[index])
                                    .font(.Body.largeBold)
                                    .foregroundColor(themeColor: .textPrimary)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                
                                AttributedText(Lucide.Icon.squareArrowUpRight.attributedString(size: 20))
                                    .font(.system(size: 20))
                                    .foregroundColor(themeColor: .textPrimary)
                                    .frame(width: 20)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if let url: URL = URL(string: links[index]) {
                                    openURL(url)
                                }
                                close(nil)
                            }
                            
                            if index != links.count - 1 {
                                Divider()
                                    .foregroundColor(themeColor: .borderSeparator)
                            }
                        }
                    }
                    .padding(.vertical, Values.mediumSpacing)
                    .padding(.horizontal, Values.mediumSmallSpacing)
                    .background(
                        RoundedRectangle(cornerRadius: 11)
                            .foregroundColor(themeColor: .toast_background)
                    )
                }
                .padding(Values.smallSpacing)
            }
            .padding(Values.mediumSpacing)
        }
    }
}
