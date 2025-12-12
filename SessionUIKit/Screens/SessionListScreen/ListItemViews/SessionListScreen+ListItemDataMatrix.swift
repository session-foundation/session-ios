// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import DifferenceKit

// MARK: - ListItemDataMatrix

public struct ListItemDataMatrix: View {
    public struct Info: Equatable, Hashable, Differentiable {
        let leadingAccessory: SessionListScreenContent.ListItemAccessory?
        let title: SessionListScreenContent.TextInfo?
        let trailingAccessory: SessionListScreenContent.ListItemAccessory?
        let tooltipInfo: SessionListScreenContent.TooltipInfo?
        let isLoading: Bool
        
        public init(
            leadingAccessory: SessionListScreenContent.ListItemAccessory? = nil,
            title: SessionListScreenContent.TextInfo? = nil,
            trailingAccessory: SessionListScreenContent.ListItemAccessory? = nil,
            tooltipInfo: SessionListScreenContent.TooltipInfo? = nil,
            isLoading: Bool
        ) {
            self.leadingAccessory = leadingAccessory
            self.title = title
            self.trailingAccessory = trailingAccessory
            self.tooltipInfo = tooltipInfo
            self.isLoading = isLoading
        }
    }
    
    @Binding var isShowingTooltip: Bool
    @Binding var tooltipContent: ThemedAttributedString
    @Binding var tooltipViewId: String
    @Binding var tooltipPosition: ViewPosition
    @Binding var tooltipArrowOffset: CGFloat
    @Binding var suppressUntil: Date
    
    let info: [[Info]]
    
    public var body: some View {
        VStack(spacing: 0) {
            ForEach(info.indices, id: \.self) { rowIndex in
                let row: [Info] = info[rowIndex]
                HStack(spacing: Values.mediumSpacing) {
                    ForEach(row.indices, id: \.self) { columnIndex in
                        let item: Info = row[columnIndex]
                        HStack(spacing: 0) {
                            if item.isLoading {
                                ProgressView()
                                    .padding(.trailing, Values.mediumSpacing)
                            }
                            
                            if let leadingAccessory = item.leadingAccessory, !item.isLoading {
                                leadingAccessory.accessoryView()
                                    .padding(.trailing, Values.mediumSpacing)
                            }
                            
                            if let title = item.title, let text = title.text {
                                Text(text.trimmingCharacters(in: .whitespaces))
                                    .font(title.font)
                                    .multilineTextAlignment(title.alignment)
                                    .foregroundColor(themeColor: title.color)
                                    .accessibility(title.accessibility)
                                    .padding(.trailing, Values.mediumSpacing)
                            }
                            
                            if let trailingAccessory = item.trailingAccessory, !item.isLoading {
                                trailingAccessory.accessoryView()
                                    .padding(.trailing, Values.mediumSpacing)
                            }
                            
                            if let tooltipInfo = item.tooltipInfo, !item.isLoading {
                                Spacer(minLength: 0)
                                
                                Image(systemName: "questionmark.circle")
                                    .font(.Body.baseRegular)
                                    .foregroundColor(themeColor: tooltipInfo.tintColor)
                                    .anchorView(viewId: tooltipInfo.id)
                                    .accessibility(
                                        Accessibility(identifier: "Data Matrix Tooltip")
                                    )
                                    .onTapGesture {
                                        guard Date() >= suppressUntil else { return }
                                        suppressUntil = Date().addingTimeInterval(0.2)
                                        guard tooltipViewId != tooltipInfo.id && !isShowingTooltip else {
                                            withAnimation {
                                                isShowingTooltip = false
                                            }
                                            return
                                        }
                                        tooltipContent = tooltipInfo.content
                                        tooltipPosition = tooltipInfo.position
                                        tooltipViewId = tooltipInfo.id
                                        tooltipArrowOffset = 16
                                        withAnimation {
                                            isShowingTooltip = true
                                        }
                                    }
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
            .contentShape(Rectangle())
        }
    }
}
