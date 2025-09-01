// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SwiftUI
import Lucide
import GRDB
import DifferenceKit
import SessionUIKit
import SignalUtilitiesKit
import SessionMessagingKit
import SessionUtilitiesKit

public class SessionProSettingsViewModel: SessionListScreenContent.ViewModelType, NavigatableStateHolder {
    public let dependencies: Dependencies
    public let navigatableState: NavigatableState = NavigatableState()
    public let state: SessionListScreenContent.ListItemDataState<Section, ListItem> = SessionListScreenContent.ListItemDataState()
    
    /// This value is the current state of the view
    @MainActor @Published private(set) var internalState: ViewModelState
    private var observationTask: Task<Void, Never>?
    
    // MARK: - Initialization
    
    @MainActor init(
        using dependencies: Dependencies
    ) {
        self.dependencies = dependencies
        self.internalState = ViewModelState.initialState()
        
        self.observationTask = ObservationBuilder
            .initialValue(self.internalState)
            .debounce(for: .never)
            .using(dependencies: dependencies)
            .query(SessionProSettingsViewModel.queryState)
            .assign { [weak self] updatedState in
                guard let self = self else { return }
                
                self.state.updateTableData(updatedState.sections(viewModel: self, previousState: self.internalState))
                self.internalState = updatedState
            }
    }
    
    // MARK: - Config
    
    public enum Section: SessionListScreenContent.ListSection {
        case logoWithPro
        case proStats
        case proSettings
        case proFeatures
        case proManagement
        case help
        
        public var title: String? {
            switch self {
                case .proStats: return "Your Pro Stats"
                case .proSettings: return "Pro Settings"
                case .proFeatures: return "Pro Features"
                case .proManagement: return "Manage Pro"
                case .help: return "sessionHelp".localized()
                default: return nil
            }
        }
        
        public var style: SessionListScreenContent.ListSectionStyle {
            switch self {
                case .proStats: return .titleWithTooltips
                case .proSettings, .proFeatures, .proManagement, .help: return .titleNoBackgroundContent
                default: return .none
            }
        }
        
        public var footer: String? { return nil }
    }
    
    public enum ListItem: Differentiable {
        case logoWithPro
        
        case proStats
        
        case updatePlan
        case proBadge
        
        case largerGroups
        case longerMessages
        case animatedDisplayPictures
        case badges
        case unlimitedPins
        case plusLoadsMore
        
        case cancelPlan
        case requestRefund
        
        case faq
        case support
    }
    
    // MARK: - Content
    
    public struct ViewModelState: ObservableKeyProvider {
        let numberOfGroupsUpgraded: Int
        let numberOfPinnedConversations: Int
        let numberOfProBadgesSent: Int
        let numberOfLongerMessagesSent: Int
        @State var isProBadgeEnabled: Bool
        
        @MainActor public func sections(viewModel: SessionProSettingsViewModel, previousState: ViewModelState) -> [SectionModel] {
            SessionProSettingsViewModel.sections(
                state: self,
                previousState: previousState,
                viewModel: viewModel
            )
        }
        
        public let observedKeys: Set<ObservableKey> = [
            .setting(.groupsUpgradedCounter),
            .setting(.pinnedConversationsCounter),
            .setting(.proBadgesSentCounter),
            .setting(.longerMessagesSentCounter),
            .setting(.isProBadgeEnabled)
        ]
        
        static func initialState() -> ViewModelState {
            return ViewModelState(
                numberOfGroupsUpgraded: 0,
                numberOfPinnedConversations: 0,
                numberOfProBadgesSent: 0,
                numberOfLongerMessagesSent: 0,
                isProBadgeEnabled: false
            )
        }
    }
    
    @Sendable private static func queryState(
        previousState: ViewModelState,
        events: [ObservedEvent],
        isInitialQuery: Bool,
        using dependencies: Dependencies
    ) async -> ViewModelState {
        var numberOfGroupsUpgraded: Int = previousState.numberOfGroupsUpgraded
        var numberOfPinnedConversations: Int = previousState.numberOfPinnedConversations
        var numberOfProBadgesSent: Int = previousState.numberOfProBadgesSent
        var numberOfLongerMessagesSent: Int = previousState.numberOfLongerMessagesSent
        var isProBadgeEnabled: Bool = previousState.isProBadgeEnabled
        
        /// If we have no previous state then we need to fetch the initial state
        if isInitialQuery {
            dependencies.mutate(cache: .libSession) { libSession in
                isProBadgeEnabled = libSession.get(.isProBadgeEnabled)
            }
            dependencies[singleton: .storage].read { db in
                numberOfGroupsUpgraded = db[.groupsUpgradedCounter] ?? 0
                numberOfPinnedConversations = db[.pinnedConversationsCounter] ?? 0
                numberOfProBadgesSent = db[.proBadgesSentCounter] ?? 0
                numberOfLongerMessagesSent = db[.longerMessagesSentCounter] ?? 0
            }
        }
        
        /// Process any event changes
        events.forEach { event in
            switch event.key {
                case .setting(.groupsUpgradedCounter):
                    guard let updatedValue = event.value as? Int else { return }
                    numberOfGroupsUpgraded = updatedValue
                case .setting(.pinnedConversationsCounter):
                    guard let updatedValue = event.value as? Int else { return }
                    numberOfPinnedConversations = updatedValue
                case .setting(.proBadgesSentCounter):
                    guard let updatedValue = event.value as? Int else { return }
                    numberOfProBadgesSent = updatedValue
                case .setting(.longerMessagesSentCounter):
                    guard let updatedValue = event.value as? Int else { return }
                    numberOfLongerMessagesSent = updatedValue
                case .setting(.isProBadgeEnabled):
                    guard let updatedValue = event.value as? Bool else { return }
                    isProBadgeEnabled = updatedValue
                    
                default: break
            }
        }
        
        return ViewModelState(
            numberOfGroupsUpgraded: numberOfGroupsUpgraded,
            numberOfPinnedConversations: numberOfPinnedConversations,
            numberOfProBadgesSent: numberOfProBadgesSent,
            numberOfLongerMessagesSent: numberOfLongerMessagesSent,
            isProBadgeEnabled: isProBadgeEnabled
        )
    }
    
    private static func sections(
        state: ViewModelState,
        previousState: ViewModelState,
        viewModel: SessionProSettingsViewModel
    ) -> [SectionModel] {
        let logo: SectionModel = SectionModel(
            model: .logoWithPro,
            elements: [
                SessionListScreenContent.ListItemInfo(
                    id: .logoWithPro,
                    variant: .logoWithPro
                )
            ]
        )
        
        let proStats: SectionModel = SectionModel(
            model: .proStats,
            elements: [
                SessionListScreenContent.ListItemInfo(
                    id: .proStats,
                    variant: .dataMatrix(
                        info: [
                            [
                                SessionListScreenContent.DataMatrixInfo(
                                    leadingAccessory: .icon(
                                        UIImage(named: "ic_user_group"),
                                        size: .large,
                                        customTint: .primary,
                                    ),
                                    title: .init(
                                        "\(state.numberOfGroupsUpgraded) Groups Upgraded",
                                        font: .Headings.H9
                                    )
                                ),
                                SessionListScreenContent.DataMatrixInfo(
                                    leadingAccessory: .icon(
                                        .pin,
                                        size: .large,
                                        customTint: .primary,
                                    ),
                                    title: .init(
                                        "\(state.numberOfPinnedConversations) Pinned Conversations",
                                        font: .Headings.H9
                                    )
                                )
                            ],
                            [
                                SessionListScreenContent.DataMatrixInfo(
                                    leadingAccessory: .icon(
                                        .rectangleEllipsis,
                                        size: .large,
                                        customTint: .primary,
                                    ),
                                    title: .init(
                                        "\(state.numberOfProBadgesSent) Pro Badges Sent",
                                        font: .Headings.H9
                                    )
                                ),
                                SessionListScreenContent.DataMatrixInfo(
                                    leadingAccessory: .icon(
                                        .messageSquare,
                                        size: .large,
                                        customTint: .primary,
                                    ),
                                    title: .init(
                                        "\(state.numberOfLongerMessagesSent) Longer Messages Sent",
                                        font: .Headings.H9
                                    )
                                )
                            ]
                        ]
                    )
                )
            ]
        )
        
        let proSettings: SectionModel = SectionModel(
            model: .proSettings,
            elements: [
                SessionListScreenContent.ListItemInfo(
                    id: .updatePlan,
                    variant: .cell(
                        info: .init(
                            title: .init("Update Plan", font: .Headings.H8),
                            subtitle: .init("Pro auto-renewing in 15 Days", font: .Body.smallRegular),
                            trailingAccessory: .icon(.chevronRight, size: .large)
                        )
                    ),
                    onTap: { [weak viewModel] in
                        
                    }
                ),
                SessionListScreenContent.ListItemInfo(
                    id: .proBadge,
                    variant: .cell(
                        info: .init(
                            title: .init("Pro Badge", font: .Headings.H8),
                            subtitle: .init("Show Session Pro badge to other users", font: .Body.smallRegular),
                            trailingAccessory: .toggle(state.$isProBadgeEnabled)
                        )
                    ),
                    onTap: { [weak viewModel] in
                        state.isProBadgeEnabled.toggle()
                    }
                )
            ]
        )
        
        let proFeatures: SectionModel = SectionModel(
            model: .proFeatures,
            elements: ProFeaturesInfo.allCases.map { info in
                SessionListScreenContent.ListItemInfo(
                    id: info.id,
                    variant: .cell(
                        info: .init(
                            leadingAccessory: .icon(
                                info.icon,
                                iconSize: .medium,
                                customTint: .black,
                                gradientBackgroundColors: info.backgroundColors.map { $0.colorSwiftUI },
                                backgroundSize: .veryLarge,
                                backgroundCornerRadius: 8
                            ),
                            title: .init(info.title, font: .Headings.H9),
                            description: .init(info.description, font: .Body.smallRegular, color: .textSecondary)
                        )
                    )
                )
            }.appending(
                SessionListScreenContent.ListItemInfo(
                    id: .plusLoadsMore,
                    variant: .cell(
                        info: .init(
                            leadingAccessory: .icon(
                                Lucide.image(icon: .circlePlus, size: IconSize.medium.size),
                                iconSize: .medium,
                                customTint: .black,
                                gradientBackgroundColors: [Theme.PrimaryColor.orange.colorSwiftUI, Theme.PrimaryColor.yellow.colorSwiftUI],
                                backgroundSize: .veryLarge,
                                backgroundCornerRadius: 8
                            ),
                            title: .init("Plus Loads More...", font: .Headings.H9),
                            description: .init("New features coming soon to Pro. Discover what's next on the Pro Roadmap", font: .Body.smallRegular, color: .textSecondary)
                        )
                    ),
                    onTap: { [weak viewModel] in viewModel?.openUrl(Constants.session_pro_roadmap) }
                )
            )
        )
        
        let proManagement: SectionModel = SectionModel(
            model: .proManagement,
            elements: [
                SessionListScreenContent.ListItemInfo(
                    id: .cancelPlan,
                    variant: .cell(
                        info: .init(
                            title: .init("Cancel Plan", font: .Headings.H8, color: .danger),
                            trailingAccessory: .icon(.circleX, size: .large, customTint: .danger)
                        )
                    ),
                    onTap: {
                        
                    }
                ),
                SessionListScreenContent.ListItemInfo(
                    id: .requestRefund,
                    variant: .cell(
                        info: .init(
                            title: .init("Request Refund", font: .Headings.H8, color: .danger),
                            trailingAccessory: .icon(.circleAlert, size: .large, customTint: .danger)
                        )
                    ),
                    onTap: { [weak viewModel] in
                        
                    }
                )
            ]
        )
        
        let help: SectionModel = SectionModel(
            model: .help,
            elements: [
                SessionListScreenContent.ListItemInfo(
                    id: .faq,
                    variant: .cell(
                        info: .init(
                            title: .init("Pro FAQ", font: .Headings.H8),
                            subtitle: .init("Find answers to common questions in the Session Pro FAQ.", font: .Body.smallRegular),
                            trailingAccessory: .icon(.squareArrowUpRight, size: .large, customTint: .primary)
                        )
                    ),
                    onTap: { [weak viewModel] in viewModel?.openUrl(Constants.session_pro_faq_url) }
                ),
                SessionListScreenContent.ListItemInfo(
                    id: .support,
                    variant: .cell(
                        info: .init(
                            title: .init("Support", font: .Headings.H8),
                            subtitle: .init("Need help with your Pro plan? Submit a request to the support team.", font: .Body.smallRegular),
                            trailingAccessory: .icon(.squareArrowUpRight, size: .large, customTint: .primary)
                        )
                    ),
                    onTap: { [weak viewModel] in viewModel?.openUrl(Constants.session_pro_support_url) }
                )
            ]
        )
        
        return [ logo, proStats, proSettings, proFeatures, proManagement, help ]
    }
}

// MARK: - Interactions

extension SessionProSettingsViewModel {
    func openUrl(_ urlString: String) {
        guard let url: URL = URL(string: urlString) else { return }
        
        let modal: ConfirmationModal = ConfirmationModal(
            info: ConfirmationModal.Info(
                title: "urlOpen".localized(),
                body: .attributedText(
                    "urlOpenDescription"
                        .put(key: "url", value: url.absoluteString)
                        .localizedFormatted(baseFont: .systemFont(ofSize: Values.smallFontSize))
                ),
                confirmTitle: "open".localized(),
                confirmStyle: .danger,
                cancelTitle: "urlCopy".localized(),
                cancelStyle: .alert_text,
                hasCloseButton: true,
                onConfirm:  { modal in
                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                    modal.dismiss(animated: true)
                },
                onCancel: { _ in
                    UIPasteboard.general.string = url.absoluteString
                }
            )
        )
        
        self.transitionToScreen(modal, transitionType: .present)
    }
}

// MARK: - Pro Features Info

extension SessionProSettingsViewModel {
    struct ProFeaturesInfo {
        let id: ListItem
        let icon: UIImage?
        let backgroundColors: [Theme.PrimaryColor]
        let title: String
        let description: String
        
        static let allCases: [ProFeaturesInfo] = [
            ProFeaturesInfo(
                id: .largerGroups,
                icon: UIImage(named: "ic_user_group_plus"),
                backgroundColors: [.green, .blue],
                title: "Larger Groups",
                description: "Groups you are an admin in are automatically upgraded to support 300 members."
            ),
            ProFeaturesInfo(
                id: .longerMessages,
                icon: Lucide.image(icon: .messageSquare, size: IconSize.medium.size),
                backgroundColors: [.blue, .purple],
                title: "Longer Messages",
                description: "You can send messages up to 10,000 characters in all conversations."
            ),
            ProFeaturesInfo(
                id: .animatedDisplayPictures,
                icon: Lucide.image(icon: .squarePlay, size: IconSize.medium.size),
                backgroundColors: [.purple, .pink],
                title: "Animated Display Pictures",
                description: "Set animated GIFs and WebP images as your display picture."
            ),
            ProFeaturesInfo(
                id: .badges,
                icon: Lucide.image(icon: .rectangleEllipsis, size: IconSize.medium.size),
                backgroundColors: [.pink, .red],
                title: "Badges",
                description: "Show your support for Session with an exclusive badge next to your display name."
            ),
            ProFeaturesInfo(
                id: .unlimitedPins,
                icon: Lucide.image(icon: .pin, size: IconSize.medium.size),
                backgroundColors: [.red, .orange],
                title: "Unlimited Pins",
                description: "Organize all your chats with unlimited pinned conversations."
            )
        ]
    }
}
