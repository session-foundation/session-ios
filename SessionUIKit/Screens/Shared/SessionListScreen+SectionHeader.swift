// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

extension SessionListScreen {
    struct SectionHeader: View {
        @State var isShowingTooltip: Bool = false
        @State var tooltipContentFrame: CGRect = CGRect.zero
        
        let section: any SessionListScreenContent.ListSection
        let tooltipViewId: String = "SessionListScreen.SectionHeader.ToolTips" // stringlint:ignore
        
        var body: some View {
            if
                let title: String = section.title,
                section.style != .none
            {
                switch section.style {
                    case .titleNoBackgroundContent:
                        Text(title)
                            .font(.Body.baseRegular)
                            .foregroundColor(themeColor: .textSecondary)
                    case .titleWithTooltips:
                        HStack(spacing: Values.verySmallSpacing) {
                            Text(title)
                                .font(.Body.baseRegular)
                                .foregroundColor(themeColor: .textSecondary)
                            
                            Button {
                                withAnimation {
                                    isShowingTooltip.toggle()
                                }
                            } label: {
                                Image(systemName: "questionmark.circle")
                                    .font(.Body.baseRegular)
                                    .foregroundColor(themeColor: .textSecondary)
                            }
                            .anchorView(viewId: tooltipViewId)
                            .accessibility(
                                Accessibility(identifier: "Tooltip")
                            )
                            
                            Spacer()
                        }
                        .popoverView(
                            content: {
                                ZStack {
                                    Text("Pro stats reflect usage on this device and may appear differently on linked devices")
                                        .font(.Body.smallRegular)
                                        .multilineTextAlignment(.center)
                                        .foregroundColor(themeColor: .textPrimary)
                                        .padding(.horizontal, Values.mediumSpacing)
                                        .padding(.vertical, Values.smallSpacing)
                                        .frame(maxWidth: 250)
                                }
                                .overlay(
                                    GeometryReader { geometry in
                                        Color.clear // Invisible overlay
                                            .onAppear {
                                                self.tooltipContentFrame = geometry.frame(in: .global)
                                            }
                                    }
                                )
                            },
                            backgroundThemeColor: .toast_background,
                            isPresented: $isShowingTooltip,
                            frame: $tooltipContentFrame,
                            position: .topRight,
                            viewId: tooltipViewId
                        )
                    case .none:
                        EmptyView()
                }
            } else {
                EmptyView()
            }
        }
    }
}
