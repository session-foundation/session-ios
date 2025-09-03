// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

public struct SessionListScreen<ViewModel: SessionListScreenContent.ViewModelType>: View {
    @EnvironmentObject var host: HostWrapper
    @StateObject private var viewModel: ViewModel
    @State var isShowingTooltip: Bool = false
    @State var tooltipContentFrame: CGRect = CGRect.zero
    @State var tooltipContent: String = ""
    
    private let tooltipViewId: String = "SessionListScreen.SectionHeader.ToolTips" // stringlint:ignore
    private let coordinateSpaceName: String = "SessionListScreen" // stringlint:ignore
    
    public init(viewModel: ViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }
    
    public var body: some View {
        List {
            ForEach(viewModel.state.listItemData, id: \.model) { section in 
                Section {
                    // MARK: - Header
                    
                    if let title: String = section.model.title, section.model.style != .none {
                        HStack(spacing: 0) {
                            Text(title)
                                .font(.Body.baseRegular)
                                .foregroundColor(themeColor: .textSecondary)
                                .padding(.horizontal, Values.smallSpacing)
                            
                            if case .titleWithTooltips(let content) = section.model.style {
                                Image(systemName: "questionmark.circle")
                                    .font(.Body.baseRegular)
                                    .foregroundColor(themeColor: .textSecondary)
                                    .onAppear {
                                        tooltipContent = content
                                    }
                                    .anchorView(viewId: tooltipViewId)
                                    .accessibility(
                                        Accessibility(identifier: "Tooltip")
                                    )
                                    .onTapGesture {
                                        withAnimation {
                                            isShowingTooltip.toggle()
                                        }
                                    }
                            }
                        }
                    }
                    
                    // MARK: List Items
                    
                    VStack(spacing: 0) {
                        ForEach(section.elements.indices, id: \.self) { index in
                            let element = section.elements[index]
                            let isLastElement: Bool = (index == section.elements.count - 1)
                            switch element.variant {
                                case .cell(let info):
                                    ListItemCell(info: info, height: section.model.style.height)
                                        .onTapGesture {
                                            element.onTap?()
                                        }
                                        .padding(.vertical, Values.smallSpacing)
                                        .padding(.top, (index == 0) ? Values.smallSpacing : 0)
                                        .padding(.bottom, isLastElement ? Values.smallSpacing : 0)
                                        .background(
                                            Rectangle()
                                                .foregroundColor(themeColor: .backgroundSecondary)
                                        )
                                    
                                if (section.model.divider && !isLastElement) {
                                    Divider()
                                        .foregroundColor(themeColor: .borderSeparator)
                                        .padding(.horizontal, Values.mediumSpacing)
                                }
                                case .logoWithPro:
                                    ListItemLogWithPro()
                                case .dataMatrix(let info):
                                    ListItemDataMatrix(info: info)
                                        .onTapGesture {
                                            element.onTap?()
                                        }
                                        .background(
                                            Rectangle()
                                                .foregroundColor(themeColor: .backgroundSecondary)
                                        )
                            }
                        }
                    }
                    .cornerRadius(11)
                    .padding(.vertical, Values.smallSpacing)
                    .listRowInsets(.init(top: 0, leading: Values.mediumSpacing, bottom: 0, trailing: Values.mediumSpacing))
                    .listRowBackground(Color.clear)
                }
                .listRowSeparator(.hidden)
                .listSectionSeparator(.hidden)
            }
        }
        .listStyle(.inset)
        .onAnyInteraction(scrollCoordinateSpaceName: coordinateSpaceName) {
            guard self.isShowingTooltip else {
                return
            }
            
            withAnimation(.spring()) {
                self.isShowingTooltip = false
            }
        }
        .coordinateSpace(name: coordinateSpaceName)
        .popoverView(
            content: {
                ZStack {
                    Text(tooltipContent)
                        .font(.Body.smallRegular)
                        .multilineTextAlignment(.center)
                        .foregroundColor(themeColor: .textPrimary)
                        .padding(.horizontal, Values.smallSpacing)
                        .padding(.vertical, Values.smallSpacing)
                        .frame(maxWidth: 270)
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
    }
}

//#if DEBUG
//extension SessionListScreenContent {
//    class PreviewViewModel: ViewModelType {
//    }
//}
//
//#Preview {
//    SessionListScreen(
//        viewModel: SessionListScreenContent.PreviewViewModel()
//    )
//}
//#endif
