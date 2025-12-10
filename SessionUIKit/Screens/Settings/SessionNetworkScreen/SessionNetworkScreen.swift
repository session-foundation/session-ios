// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Lucide

public struct SessionNetworkScreen<ViewModel: SessionNetworkScreenContent.ViewModelType>: View {
    @EnvironmentObject var host: HostWrapper
    @StateObject private var viewModel: ViewModel
    @State private var walletAddress: String = ""
    @State private var errorString: String? = nil
    @State private var copied: String? = nil
    @State private var isShowingTooltip: Bool = false
    private let coordinateSpaceName: String = "NetworkScreen" // stringlint:ignore
    
    public init(viewModel: ViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }
    
    public var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(
                    alignment: .leading,
                    spacing: Values.mediumSmallSpacing
                ) {
                    SessionNetworkSection(
                        linkOutAction: {
                            openUrl(Constants.session_network_url)
                        }
                    )
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                    
                    StatsSection(
                        dataModel: $viewModel.dataModel,
                        isRefreshing: $viewModel.isRefreshing,
                        lastRefreshWasSuccessful: $viewModel.lastRefreshWasSuccessful,
                        isShowingTooltip: $isShowingTooltip
                    )
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                    
                    SessionTokenSection(
                        dataModel: $viewModel.dataModel,
                        isRefreshing: $viewModel.isRefreshing,
                        linkOutAction: {
                            openUrl(Constants.session_staking_url)
                        }
                    )
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                    
                    if let lastUpdatedTimeString = viewModel.lastUpdatedTimeString {
                        ZStack {
                            Text(
                                "updated"
                                    .put(key: "relative_time", value: lastUpdatedTimeString)
                                    .localized()
                            )
                            .font(.Body.custom(Values.smallFontSize))
                            .foregroundColor(themeColor: .textSecondary)
                            .frame(
                                maxWidth: .infinity,
                                alignment: .center
                            )
                            .padding(.top, Values.largeSpacing)
                            .accessibility(
                                Accessibility(identifier: "Last updated timestamp")
                            )
                        }
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .bottom
                        )
                    }
                }
                .padding(Values.largeSpacing)
                .frame(
                    maxWidth: .infinity,
                    minHeight: geometry.size.height
                )
                .onAnyInteraction(scrollCoordinateSpaceName: coordinateSpaceName) {
                    guard self.isShowingTooltip else {
                        return
                    }
                    
                    withAnimation(.spring()) {
                        self.isShowingTooltip = false
                    }
                }
            }
            .onAppear {
                viewModel.fetchDataFromNetwork()
            }
            .refreshable {
                viewModel.fetchDataFromNetwork()
            }
            .backgroundColor(themeColor: .backgroundPrimary)
            .toastView(message: $copied)
            .coordinateSpace(name: coordinateSpaceName)
        }
    }
    
    private func openUrl(_ urlString: String) {
        guard let url: URL = URL(string: urlString) else { return }
        
        let modal: ConfirmationModal = ConfirmationModal(
            info: ConfirmationModal.Info(
                title: "urlOpen".localized(),
                body: .attributedText(
                    "urlOpenDescription"
                        .put(key: "url", value: url.absoluteString)
                        .localizedFormatted(baseFont: .systemFont(ofSize: Values.smallFontSize)),
                    scrollMode: .automatic
                ),
                confirmTitle: "open".localized(),
                confirmStyle: .danger,
                cancelTitle: "urlCopy".localized(),
                cancelStyle: .alert_text,
                onConfirm:  { _ in viewModel.openURL(url) },
                onCancel: { modal in
                    UIPasteboard.general.string = url.absoluteString
                    modal.close()
                }
            )
        )
        
        self.host.controller?.present(modal, animated: true)
    }
}

// MARK: - Session Network Section
/// - Session Network explanation

extension SessionNetworkScreen {
    struct SessionNetworkSection: View {
        var linkOutAction: () -> ()
        
        var body: some View {
            VStack(
                alignment: .leading,
                spacing: Values.verySmallSpacing
            ) {
                Text(Constants.network_name)
                    .font(.Body.custom(Values.smallFontSize))
                    .foregroundColor(themeColor: .textSecondary)
                
                AttributedText(
                    "sessionNetworkDescription"
                        .put(key: "network_name", value: Constants.network_name)
                        .put(key: "token_name_long", value: Constants.token_name_long)
                        .put(key: "app_name", value: Constants.app_name)
                        .put(key: "icon", value: Lucide.Icon.squareArrowUpRight)
                        .localizedFormatted(Fonts.Body.largeRegular)
                )
                .font(Font.Body.largeRegular)
                .foregroundColor(themeColor: .textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibility(
                    Accessibility(identifier: "Learn more link")
                )
            }
            .contentShape(Rectangle())
            .onTapGesture {
                linkOutAction()
            }
        }
    }
}

// MARK: - Stats Section
/// - Swarm image
/// - Snodes in current user's swarm
/// - Snodes in total
/// - SESH price
/// - SESH in swarm + total price

extension SessionNetworkScreen {
    struct StatsSection: View {
        @Binding var dataModel: SessionNetworkScreenContent.DataModel
        @Binding var isRefreshing: Bool
        @Binding var lastRefreshWasSuccessful: Bool
        @Binding var isShowingTooltip: Bool
        
        let tooltipViewId: String = "SessionNetworkScreenToolTip" // stringlint:ignore
        let scaleRatio: CGFloat = max(UIScreen.main.bounds.width / 390, 1.0)
        
        var body: some View {
            HStack(
                alignment: .top,
                spacing: 0
            ) {
                VStack(
                    alignment: .leading,
                    spacing: Values.mediumSmallSpacing
                ) {
                    ZStack {
                        if isRefreshing || !lastRefreshWasSuccessful {
                            ProgressView()
                        } else if dataModel.snodesInCurrentSwarm > 0 {
                            Image("connection_\(dataModel.snodesInCurrentSwarm)")
                                .renderingMode(.template)
                                .foregroundColor(themeColor: .textPrimary)
                            
                            Image("snodes_\(dataModel.snodesInCurrentSwarm)")
                                .renderingMode(.template)
                                .foregroundColor(themeColor: .primary)
                                .shadow(themeColor: .settings_glowingBackground, radius: 10)
                        }
                    }
                    .frame(
                        width: scaleRatio * 153,
                        height: 132
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(themeColor: .primary)
                    )
                    .accessibility(
                        Accessibility(identifier: "Swarm image")
                    )
                    
                    ZStack(
                        alignment: .topLeading
                    ) {
                        HStack {
                            Spacer()
                            
                            Button {
                                guard !isRefreshing else { return }
                                withAnimation {
                                    isShowingTooltip.toggle()
                                }
                            } label: {
                                Image(systemName: "questionmark.circle")
                                    .font(.Body.baseRegular)
                                    .foregroundColor(themeColor: .textPrimary)
                                    .padding(Values.verySmallSpacing)
                            }
                            .anchorView(viewId: tooltipViewId)
                            .accessibility(
                                Accessibility(identifier: "Tooltip")
                            )
                        }

                        VStack(
                            alignment: .leading,
                            spacing: Values.verySmallSpacing
                        ) {
                            Text(
                                "sessionNetworkCurrentPrice"
                                    .put(key: "token_name_short", value: Constants.token_name_short)
                                    .localized()
                            )
                            .font(.Body.custom(Values.smallFontSize))
                            .foregroundColor(themeColor: .textPrimary)
                            .lineLimit(1)
                            .fixedSize(
                                horizontal: false,
                                vertical: true
                            )
                            .minimumScaleFactor(0.5)
                            
                            AdaptiveText(
                                textOptions: [
                                    dataModel.tokenUSDString,
                                    dataModel.tokenUSDNoCentsString,
                                    dataModel.tokenUSDAbbreviatedString
                                ],
                                isLoading: isRefreshing
                            )
                            .font(.Headings.H5, uiKit: Fonts.Headings.H5)
                            .foregroundColor(themeColor: .sessionButton_text)
                            .loadingStyle(.text("loading".localized()))
                            
                            Text(Constants.token_name_long)
                                .font(.Body.custom(Values.smallFontSize))
                                .foregroundColor(themeColor: .textSecondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, Values.mediumSmallSpacing)
                        .padding(.vertical, Values.mediumSpacing)
                        .accessibility(
                            Accessibility(identifier: "SENT price")
                        )
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(themeColor: .backgroundSecondary)
                    )
                }
                
                Spacer(minLength: Values.mediumSmallSpacing)
                
                VStack(
                    alignment: .leading,
                    spacing: Values.mediumSmallSpacing
                ) {
                    VStack(
                        alignment: .leading,
                        spacing: Values.mediumSmallSpacing
                    ) {
                        HStack(
                            spacing: 0
                        ) {
                            AttributedText(
                                "sessionNetworkNodesSwarm"
                                    .put(key: "app_name", value: Constants.app_name)
                                    .localizedFormatted(Fonts.Body.largeBold)
                            )
                            .font(Font.Body.largeBold)
                            .foregroundColor(themeColor: .textPrimary)
                            .frame(
                                width: 116,
                                alignment: .leading
                            )
                            .fixedSize(
                                horizontal: false,
                                vertical: true
                            )
                            .minimumScaleFactor(0.5)
                            
                            ZStack {
                                if isRefreshing || !lastRefreshWasSuccessful {
                                    ProgressView()
                                } else {
                                    Text("\(dataModel.snodesInCurrentSwarm)")
                                        .font(.Headings.H3)
                                        .foregroundColor(themeColor: .sessionButton_text)
                                        .lineLimit(1)
                                        .fixedSize(
                                            horizontal: false,
                                            vertical: true
                                        )
                                        .minimumScaleFactor(0.5)
                                }
                            }
                            .frame(
                                maxWidth: .infinity,
                                alignment: .trailing
                            )
                        }
                        .accessibility(
                            Accessibility(identifier: "Your swarm amount")
                        )
                        
                        HStack(
                            spacing: 0
                        ) {
                            AttributedText(
                                "sessionNetworkNodesSecuring"
                                    .put(key: "app_name", value: Constants.app_name)
                                    .localizedFormatted(Fonts.Body.largeBold)
                            )
                            .font(Font.Body.largeBold)
                            .foregroundColor(themeColor: .textPrimary)
                            .frame(
                                width: 116,
                                alignment: .leading
                            )
                            .fixedSize(
                                horizontal: false,
                                vertical: true
                            )
                            .minimumScaleFactor(0.5)
                            
                            AdaptiveText(
                                textOptions: [
                                    dataModel.snodesInTotalString,
                                    dataModel.snodesInTotalAbbreviatedString,
                                    dataModel.snodesInTotalAbbreviatedNoDecimalString
                                ],
                                isLoading: isRefreshing || !lastRefreshWasSuccessful
                            )
                            .font(.Headings.H4, uiKit: Fonts.Headings.H4)
                            .foregroundColor(themeColor: .sessionButton_text)
                            .loadingStyle(.progressView)
                            .frame(
                                maxWidth: .infinity,
                                alignment: .trailing
                            )
                        }
                        .accessibility(
                            Accessibility(identifier: "Nodes securing amount")
                        )
                    }
                    .framing(
                        maxWidth: .infinity,
                        height: 132
                    )
                
                    VStack(
                        alignment: .leading,
                        spacing: Values.verySmallSpacing
                    ) {
                        Text("sessionNetworkSecuredBy".localized())
                            .font(.Body.custom(Values.smallFontSize))
                            .foregroundColor(themeColor: .textPrimary)
                            .lineLimit(1)
                            .fixedSize(
                                horizontal: false,
                                vertical: true
                            )
                            .minimumScaleFactor(0.5)
                        
                        Text(isRefreshing ? "loading".localized() : dataModel.networkStakedTokensString)
                            .font(.Headings.H5)
                            .foregroundColor(themeColor: .sessionButton_text)
                            .lineLimit(1)
                            .fixedSize(
                                horizontal: false,
                                vertical: true
                            )
                            .minimumScaleFactor(0.5)
                        
                        AdaptiveText(
                            textOptions: [
                                dataModel.networkStakedUSDString,
                                dataModel.networkStakedUSDAbbreviatedString
                            ],
                            isLoading: isRefreshing
                        )
                        .font(
                            .Body.custom(Values.smallFontSize),
                            uiKit: Fonts.Body.custom(Values.smallFontSize)
                        )
                        .foregroundColor(themeColor: .textSecondary)
                        .loadingStyle(.text(SessionNetworkScreenContent.DataModel.defaultPriceString))
                        .fixedSize()
                    }
                    .padding(.horizontal, Values.mediumSmallSpacing)
                    .padding(.vertical, Values.mediumSpacing)
                    .accessibility(
                        Accessibility(identifier: "Network secured amount")
                    )
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(themeColor: .backgroundSecondary)
                    )
                }
                .layoutPriority(1)
            }
            .popoverView(
                content: {
                    ZStack {
                        Text(
                            Constants.session_network_data_price
                                .put(key: "date_time", value: dataModel.priceTimeString) // stringlint:ignore
                                .localized()
                        )
                        .font(.Body.smallRegular)
                        .multilineTextAlignment(.center)
                        .foregroundColor(themeColor: .textPrimary)
                        .padding(.horizontal, Values.mediumSpacing)
                        .padding(.vertical, Values.smallSpacing)
                        .accessibility(
                            Accessibility(identifier: "Tooltip info")
                        )
                    }
                },
                backgroundThemeColor: .toast_background,
                isPresented: $isShowingTooltip,
                position: .top,
                viewId: tooltipViewId
            )
        }
    }
}

// MARK: - Session Token Section
/// - Staking rewards explanation
/// - Staking reward pool
/// - Market Cap
/// - Learn about staking button

extension SessionNetworkScreen {
    struct SessionTokenSection: View {
        @Binding var dataModel: SessionNetworkScreenContent.DataModel
        @Binding var isRefreshing: Bool
        var linkOutAction: () -> ()
        
        var body: some View {
            VStack(
                alignment: .leading,
                spacing: Values.verySmallSpacing
            ) {
                Text(Constants.token_name_long)
                    .font(.Body.custom(Values.smallFontSize))
                    .foregroundColor(themeColor: .textSecondary)
                
                Text(
                    "sessionNetworkTokenDescription"
                        .put(key: "token_name_long", value: Constants.token_name_long)
                        .put(key: "token_name_short", value: Constants.token_name_short)
                        .put(key: "staking_reward_pool", value: Constants.staking_reward_pool)
                        .localized()
                )
                .font(.Body.largeRegular)
                .foregroundColor(themeColor: .textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                
                ZStack{
                    Line(color: .borderSeparator)
                    
                    AdaptiveHStack(
                        minSpacing: Values.verySmallSpacing,
                        maxSpacing: Values.largeSpacing
                    ) {
                        VStack(
                            alignment: .leading,
                            spacing: Values.veryLargeSpacing
                        )  {
                            Text(Constants.staking_reward_pool)
                                .font(.Body.largeBold)
                                .foregroundColor(themeColor: .textPrimary)
                                .lineLimit(1)
                                .fixedSize()
                            
                            Text("sessionNetworkMarketCap".localized())
                                .font(.Body.largeBold)
                                .foregroundColor(themeColor: .textPrimary)
                                .lineLimit(1)
                                .fixedSize()
                        }
                        .padding(.vertical, Values.mediumSmallSpacing)
                        
                        VStack(
                            alignment: .leading,
                            spacing: Values.veryLargeSpacing
                        ) {
                            Text(isRefreshing ? "loading".localized() : dataModel.stakingRewardPoolString)
                                .font(.Body.largeRegular)
                                .foregroundColor(themeColor: .textPrimary)
                                .lineLimit(1)
                                .fixedSize()
                                .accessibility(
                                    Accessibility(identifier: "Staking reward pool amount")
                                )
                            
                            AdaptiveText(
                                textOptions: [
                                    dataModel.marketCapString,
                                    dataModel.marketCapAbbreviatedString
                                ],
                                isLoading: isRefreshing
                            )
                            .loadingStyle(.text("loading".localized()))
                            .font(.Body.largeRegular, uiKit: Fonts.Body.largeRegular)
                            .foregroundColor(themeColor: .textPrimary)
                            .lineLimit(1)
                            .frame(
                                maxWidth: .infinity,
                                alignment: .leading
                            )
                            .accessibility(
                                Accessibility(identifier: "Market cap amount")
                            )
                        }
                        .frame(
                            maxWidth: .infinity,
                            alignment: .leading
                        )
                        .padding(.vertical, Values.mediumSmallSpacing)
                    }
                }
                
                Button {
                    linkOutAction()
                } label: {
                    Text("sessionNetworkLearnAboutStaking".localized())
                        .font(.Body.largeRegular)
                        .foregroundColor(themeColor: .sessionButton_text)
                        .framing(
                            maxWidth: .infinity,
                            height: Values.largeButtonHeight,
                            alignment: .center
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(themeColor: .sessionButton_border)
                        )
                }
                .padding(.top, Values.mediumSmallSpacing)
                .accessibility(
                    Accessibility(identifier: "Learn about staking link")
                )
            }
        }
    }
}

#if DEBUG
extension SessionNetworkScreenContent {
    class PreviewViewModel: ViewModelType {
        var dataModel: DataModel
        var isRefreshing: Bool
        var lastRefreshWasSuccessful: Bool
        var errorString: String?
        var lastUpdatedTimeString: String?
        
        init(
            dataModel: DataModel,
            isRefreshing: Bool,
            lastRefreshWasSuccessful: Bool,
            errorString: String? = nil,
            lastUpdatedTimeString: String? = nil
        ) {
            self.dataModel = dataModel
            self.isRefreshing = isRefreshing
            self.lastRefreshWasSuccessful = lastRefreshWasSuccessful
            self.errorString = errorString
            self.lastUpdatedTimeString = lastUpdatedTimeString
        }
        
        func fetchDataFromNetwork() {}
        func isValidEthereumAddress(_ address: String) -> Bool {
            return false
        }
        func openURL(_ url: URL) {}
    }
}

#Preview {
    SessionNetworkScreen(
        viewModel: SessionNetworkScreenContent.PreviewViewModel(
            dataModel: SessionNetworkScreenContent.DataModel(
                snodesInCurrentSwarm: 6,
                snodesInTotal: 2254,
                contractAddress: "0x7D7fD4E91834A96cD9Fb2369E7f4EB72383bbdEd",
                tokenUSD: 1790.9260023480001,
                priceTimestampMs: 1745817684000,
                stakingRequirement: 20000,
                networkSize: 957,
                networkStakedTokens: 19_140_000,
                networkStakedUSD: 34_278_323_684.940723,
                stakingRewardPool: 40_010_040,
                marketCapUSD: 216_442_438_046.91196,
                lastUpdatedTimestampMs: 1745817920000
            ),
            isRefreshing: false,
            lastRefreshWasSuccessful: true,
            errorString: nil,
            lastUpdatedTimeString: "17m"
        )
    )
    .environment(\.previewTheme, (Theme.oceanDark, Theme.PrimaryColor.orange))
}
#endif
