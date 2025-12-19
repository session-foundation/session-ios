// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Combine

public struct SessionListScreen<ViewModel: SessionListScreenContent.ViewModelType>: View {
    @EnvironmentObject var host: HostWrapper
    @EnvironmentObject var toolbarManager: ToolbarManager
    @StateObject private var viewModel: ViewModel
    @ObservedObject private var state: SessionListScreenContent.ListItemDataState<ViewModel.Section, ViewModel.ListItem>
    
    // MARK: - Tooltips variables
    
    @State var isShowingTooltip: Bool = false
    @State var tooltipContent: ThemedAttributedString = ThemedAttributedString()
    @State var tooltipViewId: String = ""
    @State var tooltipPosition: ViewPosition = .top
    @State var tooltipArrowOffset: CGFloat = 30
    
    /// There is an issue on `.onAnyInteraction` of the List and `.onTapGuesture` of the TooltipsIcon. The `.onAnyInteraction` will be called first when tapping the TooltipsIcon to dismiss a tooltip.
    /// This will result in the tooltip will show again right after it dismissed when tapping the TooltipsIcon. This `suppressUntil` is a workaround to fix this issue.
    @State var suppressUntil: Date = .distantPast
    
    // MARK: Profile picture variables
    
    @State var profilePictureContent: ListItemProfilePicture.Content = .profilePicture
    @State var isProfileImageExpanding: Bool = false
    
    // MARK:
    
    private let coordinateSpaceName: String = "SessionListScreen" // stringlint:ignore
    
    // MARK: - init
    
    public init(viewModel: ViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
        _state = ObservedObject(wrappedValue: viewModel.state)
        
        if let navigatableStateHolder = viewModel as? any NavigatableStateHolder_SwiftUI {
            navigatableState = navigatableStateHolder.navigatableStateSwiftUI
        } else {
            navigatableState = nil
        }
    }
    
    // MARK: - Navigatable
    
    @State private var disposables: Set<AnyCancellable> = []
    @State private var navigationDestination: NavigationDestination? = nil
    @State private var isNavigationActive: Bool = false
    private let navigatableState: NavigatableState_SwiftUI?
    private var navigationPublisher: AnyPublisher<(NavigationDestination, TransitionType), Never> {
        navigatableState?.transitionToScreen ?? Empty().eraseToAnyPublisher()
    }
    
    @ViewBuilder
    private var destinationView: some View {
        if let destination = navigationDestination {
            destination
                .view
                .backgroundColor(themeColor: .backgroundPrimary)
                .persistentCloseToolbar()
                .environmentObject(toolbarManager)
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
        .onAppear {
            if
                let navigatableStateHolder = viewModel as? NavigatableStateHolder,
                let viewController: UIViewController = self.host.controller,
                viewController is BottomSheetIdentifiable
            {
                navigatableStateHolder.navigatableState.setupBindings(
                    viewController: viewController,
                    disposables: &disposables
                )
            }
        }
    }
    
    private var listContent: some View {
        List {
            ForEach(state.listItemData, id: \.model) { section in
                Section {
                    // MARK: - Header
                    
                    if let title: String = section.model.title, section.model.style != .none {
                        ZStack(alignment: .leading) {
                            switch section.model.style {
                                case .titleWithTooltips(let info):
                                    HStack(spacing: 0) {
                                        Text(title)
                                            .font(.Body.baseRegular)
                                            .foregroundColor(themeColor: .textSecondary)
                                            .padding(.horizontal, Values.smallSpacing)
                                        
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
                                case .titleSeparator:
                                    Seperator_SwiftUI(
                                        title: "accountId".localized(),
                                        font: .Body.baseRegular
                                    )
                                default:
                                    Text(title)
                                        .font(.Body.baseRegular)
                                        .foregroundColor(themeColor: .textSecondary)
                                        .padding(.horizontal, Values.smallSpacing)
                            }
                        }
                        .frame(minHeight: section.model.style.height)
                        .listRowInsets(.init(top: 0, leading: section.model.style.edgePadding, bottom: 0, trailing: section.model.style.edgePadding))
                        .listRowBackground(Color.clear)
                    }
                    
                    // MARK: List Items
                    
                    VStack(spacing: 0) {
                        ForEach(section.elements.indices, id: \.self) { index in
                            let element = section.elements[index]
                            let isLastElement: Bool = (index == section.elements.count - 1)
                            switch element.variant {
                                case .cell(let info):
                                    VStack(spacing: 0) {
                                        ListItemCell(
                                            info: info,
                                            onTap: element.onTap
                                        )
                                        .frame(
                                            maxWidth: .infinity,
                                            minHeight: section.model.style.cellMinHeight
                                        )
                                        .padding(.vertical, Values.smallSpacing)
                                        .padding(.top, (index == 0) ? section.model.extraVerticalPadding : 0)
                                        .padding(.bottom, isLastElement ? section.model.extraVerticalPadding : 0)
                                        
                                        if (section.model.divider && !isLastElement) {
                                            Divider()
                                                .foregroundColor(themeColor: .borderSeparator)
                                                .padding(.horizontal, Values.mediumSpacing)
                                        }
                                    }
                                    .background(
                                        Rectangle()
                                            .foregroundColor(themeColor: section.model.style.backgroundColor)
                                    )
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
                                case .profilePicture(let info):
                                    ListItemProfilePicture(
                                        content: $profilePictureContent,
                                        isProfileImageExpanding: $isProfileImageExpanding,
                                        info: info,
                                        dataManager: viewModel.imageDataManager,
                                        host: host
                                    )
                                    .padding(.vertical, Values.smallSpacing)
                                    .frame(maxWidth: .infinity, alignment: .top)
                                case .tappableText(let info):
                                    ListItemTappableText(
                                        info: info,
                                        height: section.model.style.cellMinHeight
                                    )
                                    .padding(.vertical, Values.smallSpacing)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                    .cornerRadius(11)
                    .padding(.vertical, Values.smallSpacing)
                    .listRowInsets(.init(top: 0, leading: Values.largeSpacing, bottom: 0, trailing: Values.largeSpacing))
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
