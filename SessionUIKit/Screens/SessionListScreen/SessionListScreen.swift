// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

public struct SessionListScreen<ViewModel: SessionListScreenContent.ViewModelType>: View {
    @EnvironmentObject var host: HostWrapper
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
    private var dataManager: ImageDataManagerType
    
    private let coordinateSpaceName: String = "SessionListScreen" // stringlint:ignore
    
    public init(viewModel: ViewModel, dataManager: ImageDataManagerType) {
        _viewModel = StateObject(wrappedValue: viewModel)
        _state = ObservedObject(wrappedValue: viewModel.state)
        self.dataManager = dataManager
    }
    
    public var body: some View {
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
                                        ListItemCell(info: info, height: section.model.style.cellMinHeight)
                                            .contentShape(Rectangle())
                                            .onTapGesture {
                                                element.onTap?(.item)
                                            }
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
                                            element.onTap?(.item)
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
                                        element.onTap?(.item)
                                    }
                                    .background(
                                        Rectangle()
                                            .foregroundColor(themeColor: .backgroundSecondary)
                                    )
                                case .button(let title):
                                    ListItemButton(title: title)
                                        .onTapGesture {
                                            element.onTap?(.item)
                                        }
                                case .profilePicture(let info):
                                    ListItemProfilePicture(
                                        content: $profilePictureContent,
                                        isProfileImageExpanding: $isProfileImageExpanding,
                                        info: info,
                                        dataManager: dataManager,
                                        host: host
                                    )
                                    .padding(.vertical, Values.smallSpacing)
                                    .frame(maxWidth: .infinity)
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

