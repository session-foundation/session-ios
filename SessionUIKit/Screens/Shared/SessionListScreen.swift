// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Combine

public struct SessionListScreen<ViewModel: SessionListScreenContent.ViewModelType>: View {
    @EnvironmentObject var host: HostWrapper
    @StateObject private var viewModel: ViewModel
    @ObservedObject private var state: SessionListScreenContent.ListItemDataState<ViewModel.Section, ViewModel.ListItem>
    @State var isShowingTooltip: Bool = false
    @State var tooltipContent: ThemedAttributedString = ThemedAttributedString()
    @State var tooltipViewId: String = ""
    @State var tooltipPosition: ViewPosition = .top
    @State var tooltipArrowOffset: CGFloat = 30
    
    /// There is an issue on `.onAnyInteraction` of the List and `.onTapGuesture` of the TooltipsIcon. The `.onAnyInteraction` will be called first when tapping the TooltipsIcon to dismiss a tooltip.
    /// This will result in the tooltip will show again right after it dismissed when tapping the TooltipsIcon. This `suppressUntil` is a workaround to fix this issue.
    @State var suppressUntil: Date = .distantPast
    
    private let coordinateSpaceName: String = "SessionListScreen" // stringlint:ignore
    
    private let scrollable: Bool
    
    // MARK: - init
    
    public init(viewModel: ViewModel, scrollable: Bool = true) {
        _viewModel = StateObject(wrappedValue: viewModel)
        _state = ObservedObject(wrappedValue: viewModel.state)
        self.scrollable = scrollable
        
        if let navigatableStateHolder = viewModel as? any SessionListScreenContent.NavigatableStateHolder {
            navigatableState = navigatableStateHolder.navigatableState
        } else {
            navigatableState = nil
        }
    }
    
    // MARK: - Navigatable
    
    @State private var navigationDestination: SessionListScreenContent.NavigationDestination? = nil
    @State private var isNavigationActive: Bool = false
    private let navigatableState: SessionListScreenContent.NavigatableState?
    private var navigationPublisher: AnyPublisher<(SessionListScreenContent.NavigationDestination, TransitionType), Never> {
        navigatableState?.transitionToScreen ?? Empty().eraseToAnyPublisher()
    }
    
    @ViewBuilder
    private var destinationView: some View {
        if let destination = navigationDestination {
            destination.view
        } else {
            EmptyView()
        }
    }
    
    // MARK: - Body
    
    public var body: some View {
        ZStack {
            listContent
                    
            // Hidden NavigationLink for publisher-driven navigation
            NavigationLink(
                destination: destinationView,
                isActive: $isNavigationActive
            ) {
                EmptyView()
            }
            .hidden()
        }
        .onReceive(navigationPublisher) { destination, transitionType in
            // Only handle push transitions in SwiftUI
            // Present transitions are handled by UIKit in setupBindings
            if transitionType == .push {
                navigationDestination = destination
                isNavigationActive = true
            }
        }
    }
    
    private var listContent: some View {
        ScrollableList(scrollable: self.scrollable) {
            ForEach(state.listItemData, id: \.model) { section in
                Section {
                    // MARK: - Header
                    
                    if let title: String = section.model.title, section.model.style != .none {
                        HStack(spacing: 0) {
                            Text(title)
                                .font(.Body.baseRegular)
                                .foregroundColor(themeColor: .textSecondary)
                                .padding(.horizontal, Values.smallSpacing)
                            
                            if case .titleWithTooltips(let info) = section.model.style {
                                Image(systemName: "questionmark.circle")
                                    .font(.Body.baseRegular)
                                    .foregroundColor(themeColor: .textSecondary)
                                    .anchorView(viewId: info.id)
                                    .accessibility(
                                        Accessibility(identifier: "Section Header Tooltip")
                                    )
                                    .onTapGesture {
                                        guard Date() >= suppressUntil else { return }
                                        suppressUntil = Date().addingTimeInterval(0.2)
                                        guard tooltipViewId != info.id && !isShowingTooltip else {
                                            withAnimation {
                                                isShowingTooltip = false
                                            }
                                            return
                                        }
                                        tooltipContent = info.content
                                        tooltipPosition = info.position
                                        tooltipViewId = info.id
                                        tooltipArrowOffset = 30
                                        withAnimation {
                                            isShowingTooltip = true
                                        }
                                    }
                            }
                        }
                        .padding(.vertical, (scrollable ? 0 : Values.mediumSpacing))
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
                                case .logoWithPro(let info):
                                    ListItemLogoWithPro(info: info)
                                        .onTapGesture {
                                            element.onTap?()
                                        }
                                case .dataMatrix(let info):
                                    ListItemDataMatrix(
                                        isShowingTooltip: $isShowingTooltip,
                                        tooltipContent: $tooltipContent,
                                        tooltipViewId: $tooltipViewId,
                                        tooltipPosition: $tooltipPosition,
                                        tooltipArrowOffset: $tooltipArrowOffset,
                                        suppressUntil: $suppressUntil,
                                        info: info
                                    )
                                    .onTapGesture {
                                        element.onTap?()
                                    }
                                    .background(
                                        Rectangle()
                                            .foregroundColor(themeColor: .backgroundSecondary)
                                    )
                                case .button(let title, let enabled):
                                    ListItemButton(title: title, enabled: enabled)
                                        .onTapGesture {
                                            element.onTap?()
                                        }
                            }
                        }
                    }
                    .cornerRadius(11)
                    .listRowInsets(.init(top: 0, leading: Values.mediumSpacing, bottom: 0, trailing: Values.mediumSpacing))
                    .listRowBackground(Color.clear)
                }
                .listRowSeparator(.hidden)
                .listSectionSeparator(.hidden)
                .padding(0)
            }
        }
        .listStyle(.plain)
        .modifier(HideScrollIndicators())
        .onAnyInteraction(scrollCoordinateSpaceName: coordinateSpaceName) {
            guard self.isShowingTooltip else { return }
            guard Date() >= suppressUntil else { return }
            suppressUntil = Date().addingTimeInterval(0.2)
            withAnimation {
                self.isShowingTooltip = false
            }
        }
        .coordinateSpace(name: coordinateSpaceName)
        .popoverView(
            content: {
                ZStack {
                    AttributedText(tooltipContent)
                        .font(.Body.smallRegular)
                        .multilineTextAlignment(.center)
                        .foregroundColor(themeColor: .textPrimary)
                        .padding(.horizontal, Values.mediumSpacing)
                        .padding(.vertical, Values.smallSpacing)
                        .frame(maxWidth: 270)
                }
            },
            backgroundThemeColor: .toast_background,
            isPresented: $isShowingTooltip,
            position: tooltipPosition,
            offset: tooltipArrowOffset,
            viewId: tooltipViewId
        )
    }
}
