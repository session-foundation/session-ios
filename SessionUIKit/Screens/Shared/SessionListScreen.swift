// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

public struct SessionListScreen<ViewModel: SessionListScreenContent.ViewModelType>: View {
    @EnvironmentObject var host: HostWrapper
    @StateObject private var viewModel: ViewModel
    @ObservedObject private var state: SessionListScreenContent.ListItemDataState<ViewModel.Section, ViewModel.ListItem>
    @State var isShowingTooltip: Bool = false
    @State var tooltipContent: String = ""
    
    /// There is an issue on `.onAnyInteraction` of the List and `.onTapGuesture` of the TooltipsIcon. The `.onAnyInteraction` will be called first when tapping the TooltipsIcon to dismiss a tooltip.
    /// This will result in the tooltip will show again right after it dismissed when tapping the TooltipsIcon. This `suppressUntil` is a workaround to fix this issue.
    @State var suppressUntil: Date = .distantPast
    
    private let tooltipViewId: String = "SessionListScreen.SectionHeader.ToolTips" // stringlint:ignore
    private let coordinateSpaceName: String = "SessionListScreen" // stringlint:ignore
    
    public init(viewModel: ViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
        _state = ObservedObject(wrappedValue: viewModel.state)
    }
    
    public var body: some View {
        List {
            ForEach(state.listItemData, id: \.model) { section in 
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
                                    .anchorView(viewId: tooltipViewId)
                                    .accessibility(
                                        Accessibility(identifier: "Tooltip")
                                    )
                                    .onTapGesture {
                                        guard Date() >= suppressUntil else { return }
                                        tooltipContent = content
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
                                        .contentShape(Rectangle())
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
                                case .logoWithPro(let style, let description):
                                    ListItemLogoWithPro(style: style, description: description)
                                case .dataMatrix(let info):
                                    ListItemDataMatrix(info: info)
                                        .background(
                                            Rectangle()
                                                .foregroundColor(themeColor: .backgroundSecondary)
                                        )
                                case .button(let title):
                                    ListItemButton(title: title)
                                        .onTapGesture {
                                            element.onTap?()
                                        }
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
        .listStyle(.plain)
        .modifier(HideScrollIndicators())
        .onAnyInteraction(scrollCoordinateSpaceName: coordinateSpaceName) {
            guard self.isShowingTooltip else { return }
            suppressUntil = Date().addingTimeInterval(0.2)
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
            },
            backgroundThemeColor: .toast_background,
            isPresented: $isShowingTooltip,
            position: .topRight,
            viewId: tooltipViewId
        )
    }
}

