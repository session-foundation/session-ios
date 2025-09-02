// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

extension SessionListScreen {
    struct ListItemCell: View {
        let info: SessionListScreenContent.CellInfo
        let height: CGFloat
        
        var body: some View {
            HStack(spacing: Values.mediumSpacing) {
                if let leadingAccessory = info.leadingAccessory {
                    leadingAccessory.accessoryView()
                }
                
                VStack(alignment: .leading, spacing: 0) {
                    if let title = info.title, let text = title.text {
                        Text(text)
                            .font(title.font)
                            .multilineTextAlignment(title.alignment)
                            .foregroundColor(themeColor: title.color)
                            .accessibility(title.accessibility)
                            .fixedSize()
                    }
                    
                    if let subtitle = info.subtitle, let text = subtitle.text {
                        Text(text)
                            .font(subtitle.font)
                            .multilineTextAlignment(subtitle.alignment)
                            .foregroundColor(themeColor: subtitle.color)
                            .accessibility(subtitle.accessibility)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    
                    if let description = info.description, let text = description.text {
                        Text(text)
                            .font(description.font)
                            .multilineTextAlignment(description.alignment)
                            .foregroundColor(themeColor: description.color)
                            .accessibility(description.accessibility)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .leading
                )
                
                if let trailingAccessory = info.trailingAccessory {
                    Spacer(minLength: 0)
                    trailingAccessory.accessoryView()
                }
            }
            .padding(.horizontal, Values.mediumSpacing)
            .frame(
                maxWidth: .infinity,
                minHeight: height,
                alignment: .leading
            )
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
    
    struct ListItemDataMatrix: View {
        let info: [[SessionListScreenContent.DataMatrixInfo]]
        
        var body: some View {
            VStack(spacing: 0) {
                ForEach(info.indices, id: \.self) { rowIndex in
                    let row: [SessionListScreenContent.DataMatrixInfo] = info[rowIndex]
                    HStack(spacing: Values.mediumSpacing) {
                        ForEach(row.indices, id: \.self) { columnIndex in
                            let item: SessionListScreenContent.DataMatrixInfo = row[columnIndex]
                            HStack(spacing: Values.mediumSpacing) {
                                if let leadingAccessory = item.leadingAccessory {
                                    leadingAccessory.accessoryView()
                                }
                                
                                if let title = item.title, let text = title.text {
                                    Text(text)
                                        .font(title.font)
                                        .multilineTextAlignment(title.alignment)
                                        .foregroundColor(themeColor: title.color)
                                        .accessibility(title.accessibility)
                                }
                                
                                if let trailingAccessory = item.trailingAccessory {
                                    trailingAccessory.accessoryView()
                                }
                            }
                            .frame(
                                maxWidth: .infinity,
                                alignment: .leading
                            )
                        }
                    }
                    .padding(.vertical, Values.smallSpacing)
                }
                .padding(.horizontal, Values.mediumSpacing)
                .padding(.vertical, Values.smallSpacing)
                .frame(maxWidth: .infinity)
            }
        }
    }
}
