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
                /// **Note:** `safeAreaInset` rather than an overlay so the list is actually inset by the footer -
                /// with an overlay the last row sits underneath it and can't be scrolled clear
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if viewModel.footerStyle == .sticky {
                        stickyFooter
                    }
                }
                /// **Note:** This has to be applied to the *composed* view rather than inside the footer - a child
                /// can't draw outside a parent whose frame already stops at the safe area, so ignoring it within the
                /// overlay left the gradient sitting on top of the inset rather than running past it. An empty edge
                /// set is a no-op, which keeps the inline-footer screens exactly as they were.
                .ignoresSafeArea(edges: (viewModel.footerStyle == .sticky ? .bottom : []))
                    
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
    
    /// The pinned footer, mirroring what the UIKit `SessionTableViewController` built out of a `GradientView` and a
    /// `SessionButton` overlaid on the table rather than rows within it
    ///
    /// **Note:** The whole footer ignores the bottom safe area so the gradient reaches the physical bottom of the
    /// screen, and the safe area inset is then added back as padding under the footer content - which is what the
    /// UIKit version got by pinning the fade to the view and the button to the safe area layout guide. Reading the
    /// inset from the window (rather than a `GeometryReader`) keeps it correct here, since a reader nested inside a
    /// view that ignores the safe area reports an inset of zero.
    private var stickyFooter: some View {
        viewModel.footerView
            .padding(.bottom, (Values.smallSpacing + (SNUIKit.mainWindow?.safeAreaInsets.bottom ?? 0)))
            .frame(maxWidth: .infinity)
            /// **Note:** The footer is sized to the *gradient* rather than to its content so `safeAreaInset` reserves
            /// the whole faded region - sizing it to the button alone leaves the last row sitting inside the fade
            .frame(
                height: Values.footerGradientHeight(window: SNUIKit.mainWindow),
                alignment: .bottom
            )
            .background(alignment: .bottom) {
                ThemeLinearGradient(
                    themeColors: [
                        .value(.backgroundPrimary, alpha: 0),
                        .backgroundPrimary,
                        .backgroundPrimary,
                        .backgroundPrimary,
                        .backgroundPrimary
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: Values.footerGradientHeight(window: SNUIKit.mainWindow))
                .allowsHitTesting(false)
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
                                            .scaleEffect(x: (SNUIKit.isRTL ? -1 : 1), y: 1)
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
                                        title: title,
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
                            let onTapAction: (@MainActor () -> Void) = {
                                guard var confirmationInfo = element.confirmationInfo else {
                                    element.onTap?()
                                    return
                                }
                                
                                if let elementOnTap = element.onTap {
                                    confirmationInfo = confirmationInfo.with(
                                        onConfirm: { _ in
                                            elementOnTap()
                                        }
                                    )
                                }
                                
                                let modal: ConfirmationModal = ConfirmationModal(info: confirmationInfo)
                                host.controller?.present(modal, animated: true)
                            }
                            
                            switch element.variant {
                                case .cell(let info):
                                    VStack(spacing: 0) {
                                        ListItemCell(
                                            info: info,
                                            shouldHighlight: (element.onTap != nil || element.confirmationInfo != nil),
                                            height: section.model.style.cellMinHeight,
                                            extraTopPadding: ((index == 0) ? section.model.extraVerticalPadding : 0),
                                            extraBottomPadding: (isLastElement ? section.model.extraVerticalPadding : 0),
                                            onTap: onTapAction
                                        )
                                        .accessibility(element.accessibility)
                                        
                                        if (section.model.divider && !isLastElement) {
                                            Divider()
                                                .foregroundColor(themeColor: .borderSeparator)
                                                .framing(maxWidth: .infinity, height: 1)
                                                .padding(.horizontal, Values.mediumSpacing)
                                        }
                                    }
                                    .background(
                                        Rectangle()
                                            .foregroundColor(themeColor: section.model.style.backgroundColor)
                                    )
                                case .logoWithPro(let info):
                                    ListItemLogoWithPro(info: info)
                                        .accessibility(element.accessibility)
                                        .onTapGesture {
                                            onTapAction()
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
                                    .accessibility(element.accessibility)
                                    .onTapGesture {
                                        onTapAction()
                                    }
                                    .background(
                                        Rectangle()
                                            .foregroundColor(themeColor: .backgroundSecondary)
                                    )
                                case .button(let title, let enabled):
                                    ListItemButton(title: title, enabled: enabled)
                                        .accessibility(element.accessibility)
                                        .onTapGesture {
                                            onTapAction()
                                        }
                                case .profilePicture(let info):
                                    ListItemProfilePicture(
                                        content: $profilePictureContent,
                                        isProfileImageExpanding: $isProfileImageExpanding,
                                        info: info,
                                        dataManager: viewModel.imageDataManager,
                                        host: host,
                                        onProfilePictureTap: onTapAction
                                    )
                                    .frame(maxWidth: .infinity, alignment: .top)
                                    .accessibility(element.accessibility)
                                    .accessibilityElement(children: .contain)
                                case .tappableText(let info):
                                    ListItemTappableText(
                                        info: info,
                                        height: section.model.style.cellMinHeight,
                                        onAnyTap: onTapAction
                                    )
                                    .padding(.vertical, Values.smallSpacing)
                                    .frame(maxWidth: .infinity)
                                    .accessibility(element.accessibility)
                            }
                        }
                    }
                    .cornerRadius(section.model.style.cornerRadius)
                    .padding(.vertical, Values.verySmallSpacing)
                    .dropShadow(themeColor: (section.model.shadow ? .shadow : nil), radius: 4)
                    .listRowInsets(.init(top: 0, leading: Values.largeSpacing, bottom: 0, trailing: Values.largeSpacing))
                    .listRowBackground(Color.clear)
                }
                .listRowSeparator(.hidden)
                .listSectionSeparator(.hidden)
                .padding(0)
            }
            
            /// **Note:** Gated on the screen actually having a footer - an `EmptyView` still occupies a row, which
            /// is bottom padding the list didn't ask for (most screens don't override `footerView`)
            if viewModel.footerStyle == .inline && ViewModel.FooterView.self != EmptyView.self {
                ZStack {
                    viewModel.footerView
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
                .listSectionSeparator(.hidden)
                .listRowBackground(Color.clear)
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
