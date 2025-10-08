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
    public let title: String = ""
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
                case .proStats: return "proStats".put(key: "pro", value: Constants.pro).localized()
                case .proSettings: return "proSettings".put(key: "pro", value: Constants.pro).localized()
                case .proFeatures: return "proBetaFeatures".put(key: "pro", value: Constants.pro).localized()
                case .proManagement: return "managePro".put(key: "pro", value: Constants.pro).localized()
                case .help: return "sessionHelp".localized()
                default: return nil
            }
        }
        
        public var style: SessionListScreenContent.ListSectionStyle {
            switch self {
                case .proStats: return .titleWithTooltips(content: "proStatsTooltip".put(key: "pro", value: Constants.pro).localized())
                case .proSettings, .proFeatures, .proManagement, .help: return .titleNoBackgroundContent
                default: return .none
            }
        }
        
        public var divider: Bool {
            switch self {
                case .proSettings, .proManagement, .help: return true
                default: return false
            }
        }
        
        public var footer: String? { return nil }
    }
    
    public enum ListItem: Differentiable {
        case logoWithPro
        
        case proStats
        
        case updatePlan
        case refundRequested
        case renewPlan
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
        let isProBadgeEnabled: Bool
        let currentProPlanState: SessionProPlanState
        
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
                isProBadgeEnabled: false,
                currentProPlanState: .none
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
        var currentProPlanState: SessionProPlanState = previousState.currentProPlanState
        
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
            currentProPlanState = dependencies[singleton: .sessionProState].sessionProStateSubject.value
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
            isProBadgeEnabled: isProBadgeEnabled,
            currentProPlanState: currentProPlanState
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
                    variant: .logoWithPro(
                        style:{
                            switch state.currentProPlanState {
                                case .expired: .disabled
                                default: .normal
                            }
                        }()
                    )
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
                                        "proGroupsUpgraded"
                                            .putNumber(state.numberOfGroupsUpgraded)
                                            .put(key: "total", value: state.numberOfGroupsUpgraded)
                                            .localized(),
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
                                        "proPinnedConversations"
                                            .putNumber(state.numberOfPinnedConversations)
                                            .put(key: "total", value: state.numberOfPinnedConversations)
                                            .localized(),
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
                                        "proBadgesSent"
                                            .putNumber(state.numberOfProBadgesSent)
                                            .put(key: "total", value: state.numberOfProBadgesSent)
                                            .put(key: "pro", value: Constants.pro)
                                            .localized(),
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
                                        "proLongerMessagesSent"
                                            .putNumber(state.numberOfLongerMessagesSent)
                                            .put(key: "total", value: state.numberOfLongerMessagesSent)
                                            .localized(),
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
                {
                    switch state.currentProPlanState {
                    case .none: nil
                    case .active(_, let expiredOn, _, _):
                        SessionListScreenContent.ListItemInfo(
                            id: .updatePlan,
                            variant: .cell(
                                info: .init(
                                    title: .init("updatePlan".localized(), font: .Headings.H8),
                                    description: .init(
                                        font: .Body.smallRegular,
                                        attributedString: "proAutoRenewTime"
                                            .put(key: "pro", value: Constants.pro)
                                            .put(key: "time", value: expiredOn.timeIntervalSinceNow.formatted(format: .long, minimumUnit: .day))
                                            .localizedFormatted(Fonts.Body.smallRegular)
                                    ),
                                    trailingAccessory: .icon(.chevronRight, size: .large)
                                )
                            ),
                            onTap: { [weak viewModel] in viewModel?.updateProPlan() }
                        )
                    case .expired:
                        SessionListScreenContent.ListItemInfo(
                            id: .refundRequested,
                            variant: .cell(
                                info: .init(
                                    title: .init(
                                        "proPlanRenew"
                                            .put(key: "pro", value: Constants.pro)
                                            .localized(),
                                        font: .Headings.H8,
                                        color: .primary
                                    ),
                                    trailingAccessory: .icon(
                                        .circlePlus,
                                        size: .large,
                                        customTint: .primary
                                    )
                                )
                            ),
                            onTap: { [weak viewModel] in viewModel?.updateProPlan() }
                        )
                    case .refunding(let originatingPlatform, _):
                        SessionListScreenContent.ListItemInfo(
                            id: .refundRequested,
                            variant: .cell(
                                info: .init(
                                    title: .init("proRequestedRefund".localized(), font: .Headings.H8),
                                    description: .init(
                                        font: .Body.smallRegular,
                                        attributedString: "processingRefundRequest"
                                            .put(key: "platform", value: originatingPlatform.name)
                                            .localizedFormatted(Fonts.Body.smallRegular)
                                    ),
                                    trailingAccessory: .icon(.circleAlert, size: .large)
                                )
                            ),
                            onTap: { [weak viewModel] in viewModel?.updateProPlan() }
                        )
                    }
                    
                }(),
                SessionListScreenContent.ListItemInfo(
                    id: .proBadge,
                    variant: .cell(
                        info: .init(
                            title: .init("proBadge".put(key: "pro", value: Constants.pro).localized(), font: .Headings.H8),
                            description: .init("proBadgeVisible".put(key: "app_pro", value: Constants.app_pro).localized(), font: .Body.smallRegular),
                            trailingAccessory: .toggle(
                                state.isProBadgeEnabled,
                                oldValue: previousState.isProBadgeEnabled
                            )
                        )
                    ),
                    onTap: { [dependencies = viewModel.dependencies] in
                        dependencies.setAsync(.isProBadgeEnabled, !state.isProBadgeEnabled)
                    }
                )
            ].compactMap { $0 }
        )
        
        let proFeatures: SectionModel = SectionModel(
            model: .proFeatures,
            elements: ProFeaturesInfo.allCases(state.currentProPlanState).map { info in
                SessionListScreenContent.ListItemInfo(
                    id: info.id,
                    variant: .cell(
                        info: .init(
                            leadingAccessory: .icon(
                                info.icon,
                                iconSize: .medium,
                                customTint: .black,
                                gradientBackgroundColors: info.backgroundColors,
                                backgroundSize: .veryLarge,
                                backgroundCornerRadius: 8
                            ),
                            title: .init(info.title, font: .Headings.H9, accessory: info.accessory),
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
                                gradientBackgroundColors: {
                                    return switch state.currentProPlanState {
                                        case .expired: [ThemeValue.disabled]
                                        default: [.explicitPrimary(.orange), .explicitPrimary(.yellow)]
                                    }
                                }(),
                                backgroundSize: .veryLarge,
                                backgroundCornerRadius: 8
                            ),
                            title: .init("plusLoadsMore".localized(), font: .Headings.H9),
                            description: .init(
                                font: .Body.smallRegular,
                                attributedString: "plusLoadsMoreDescription"
                                    .put(key: "pro", value: Constants.pro)
                                    .put(key: "icon", value: Lucide.Icon.squareArrowUpRight)
                                    .localizedFormatted(Fonts.Body.smallRegular),
                                color: .textSecondary
                            )
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
                            title: .init("cancelPlan".localized(), font: .Headings.H8, color: .danger),
                            trailingAccessory: .icon(.circleX, size: .large, customTint: .danger)
                        )
                    ),
                    onTap: { [weak viewModel] in viewModel?.cancelPlan() }
                ),
                SessionListScreenContent.ListItemInfo(
                    id: .requestRefund,
                    variant: .cell(
                        info: .init(
                            title: .init("requestRefund".localized(), font: .Headings.H8, color: .danger),
                            trailingAccessory: .icon(.circleAlert, size: .large, customTint: .danger)
                        )
                    ),
                    onTap: { [weak viewModel] in viewModel?.requestRefund() }
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
                            title: .init("proFaq".put(key: "pro", value: Constants.pro).localized(), font: .Headings.H8),
                            description: .init("proFaqDescription".put(key: "app_pro", value: Constants.app_pro).localized(), font: .Body.smallRegular),
                            trailingAccessory: .icon(.squareArrowUpRight, size: .large, customTint: .primary)
                        )
                    ),
                    onTap: { [weak viewModel] in viewModel?.openUrl(Constants.session_pro_faq_url) }
                ),
                SessionListScreenContent.ListItemInfo(
                    id: .support,
                    variant: .cell(
                        info: .init(
                            title: .init("helpSupport".localized(), font: .Headings.H8),
                            description: .init("proSupportDescription".put(key: "pro", value: Constants.pro).localized(), font: .Body.smallRegular),
                            trailingAccessory: .icon(.squareArrowUpRight, size: .large, customTint: .primary)
                        )
                    ),
                    onTap: { [weak viewModel] in viewModel?.openUrl(Constants.session_pro_support_url) }
                )
            ]
        )
        
        return switch state.currentProPlanState {
            case .none:
                [ logo, proSettings, proFeatures, help ]
            case .active:
                [ logo, proStats, proSettings, proFeatures, proManagement, help ]
            case .expired:
                [ logo, proSettings, proFeatures, help ]
            case .refunding:
                [ logo, proStats, proSettings, proFeatures, help ]
        }
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
    
    func updateProPlan() {
        let viewController: SessionHostingViewController = SessionHostingViewController(
            rootView: SessionProPaymentScreen(
                dataModel: .init(
                    flow: dependencies[singleton: .sessionProState].sessionProStateSubject.value.toPaymentFlow(),
                    plans: dependencies[singleton: .sessionProState].sessionProPlans.map { $0.info() }
                )
            )
        )
        self.transitionToScreen(viewController)
    }
    
    func cancelPlan() {
        let viewController: SessionHostingViewController = SessionHostingViewController(
            rootView: SessionProPaymentScreen(
                dataModel: .init(
                    flow: .cancel(
                        originatingPlatform: {
                            switch dependencies[singleton: .sessionProState].sessionProStateSubject.value.originatingPlatform {
                                case .iOS: return .iOS
                                case .Android: return .Android
                            }
                        }()
                    ),
                    plans: dependencies[singleton: .sessionProState].sessionProPlans.map { $0.info() }
                )
            )
        )
        self.transitionToScreen(viewController)
    }
    
    func requestRefund() {
        let viewController: SessionHostingViewController = SessionHostingViewController(
            rootView: SessionProPaymentScreen(
                dataModel: .init(
                    flow: .refund(
                        originatingPlatform: {
                            switch dependencies[singleton: .sessionProState].sessionProStateSubject.value.originatingPlatform {
                                case .iOS: return .iOS
                                case .Android: return .Android
                            }
                        }(),
                        requestedAt: nil
                    ),
                    plans: dependencies[singleton: .sessionProState].sessionProPlans.map { $0.info() }
                )
            )
        )
        self.transitionToScreen(viewController)
    }
}

// MARK: - Pro Features Info

extension SessionProSettingsViewModel {
    struct ProFeaturesInfo {
        let id: ListItem
        let icon: UIImage?
        let backgroundColors: [ThemeValue]
        let title: String
        let description: String
        let accessory: SessionListScreenContent.TextInfo.Accessory
        
        static func allCases(_ state: SessionProPlanState) -> [ProFeaturesInfo] {
            return [
                ProFeaturesInfo(
                    id: .largerGroups,
                    icon: UIImage(named: "ic_user_group_plus"),
                    backgroundColors: {
                        return switch state {
                            case .expired: [ThemeValue.disabled]
                            default: [.explicitPrimary(.green), .explicitPrimary(.blue)]
                        }
                    }(),
                    title: "proLargerGroups".localized(),
                    description: "proLargerGroupsDescription".localized(),
                    accessory: .none
                ),
                ProFeaturesInfo(
                    id: .longerMessages,
                    icon: Lucide.image(icon: .messageSquare, size: IconSize.medium.size),
                    backgroundColors: {
                        return switch state {
                            case .expired: [ThemeValue.disabled]
                            default: [.explicitPrimary(.blue), .explicitPrimary(.purple)]
                        }
                    }(),
                    title: "proLongerMessages".localized(),
                    description: "proLongerMessagesDescription".localized(),
                    accessory: .none
                ),
                ProFeaturesInfo(
                    id: .animatedDisplayPictures,
                    icon: Lucide.image(icon: .squarePlay, size: IconSize.medium.size),
                    backgroundColors: {
                        return switch state {
                            case .expired: [ThemeValue.disabled]
                            default: [.explicitPrimary(.purple), .explicitPrimary(.pink)]
                        }
                    }(),
                    title: "proAnimatedDisplayPictures".localized(),
                    description: "proAnimatedDisplayPicturesDescription".localized(),
                    accessory: .none
                ),
                ProFeaturesInfo(
                    id: .badges,
                    icon: Lucide.image(icon: .rectangleEllipsis, size: IconSize.medium.size),
                    backgroundColors: {
                        return switch state {
                            case .expired: [ThemeValue.disabled]
                            default: [.explicitPrimary(.pink), .explicitPrimary(.red)]
                        }
                    }(),
                    title: "proBadges".localized(),
                    description: "proBadgesDescription".put(key: "app_name", value: Constants.app_name).localized(),
                    accessory: .proBadgeLeading
                ),
                ProFeaturesInfo(
                    id: .unlimitedPins,
                    icon: Lucide.image(icon: .pin, size: IconSize.medium.size),
                    backgroundColors: {
                        return switch state {
                            case .expired: [ThemeValue.disabled]
                            default: [.explicitPrimary(.red), .explicitPrimary(.orange)]
                        }
                    }(),
                    title: "proUnlimitedPins".localized(),
                    description: "proUnlimitedPinsDescription".localized(),
                    accessory: .none
                )
            ]
        }
    }
}

// MARK: - Convenience

extension SessionProPlan {
    func info() -> SessionProPaymentScreenContent.SessionProPlanInfo {
        let price: Double = self.variant.price
        let pricePerMonth: Double = (self.variant.price / Double(self.variant.duration))
        return .init(
            duration: self.variant.duration,
            totalPrice: price,
            pricePerMonth: pricePerMonth,
            discountPercent: self.variant.discountPercent,
            titleWithPrice: {
                switch self.variant {
                    case .oneMonth:
                        return "proPriceOneMonth"
                            .put(key: "monthly_price", value: pricePerMonth.formatted(format: .currency(decimal: true, withLocalSymbol: true)))
                            .localized()
                    case .threeMonths:
                        return "proPriceThreeMonths"
                            .put(key: "monthly_price", value: pricePerMonth.formatted(format: .currency(decimal: true, withLocalSymbol: true)))
                            .localized()
                    case .twelveMonths:
                        return "proPriceTwelveMonths"
                            .put(key: "monthly_price", value: pricePerMonth.formatted(format: .currency(decimal: true, withLocalSymbol: true)))
                            .localized()
                }
            }(),
            subtitleWithPrice: {
                switch self.variant {
                    case .oneMonth:
                        return "proBilledMonthly"
                            .put(key: "price", value: price.formatted(format: .currency(decimal: true, withLocalSymbol: true)))
                            .localized()
                    case .threeMonths:
                        return "proBilledQuarterly"
                            .put(key: "price", value: price.formatted(format: .currency(decimal: true, withLocalSymbol: true)))
                            .localized()
                    case .twelveMonths:
                        return "proBilledAnnually"
                            .put(key: "price", value: price.formatted(format: .currency(decimal: true, withLocalSymbol: true)))
                            .localized()
                }
            }()
        )
    }
}

extension SessionProPlanState {
    func toPaymentFlow() -> SessionProPaymentScreenContent.SessionProPlanPaymentFlow {
        switch self {
            case .none:
                return .purchase
            case .active(let currentPlan, let expiredOn, let isAutoRenewing, let originatingPlatform):
                return .update(
                    currentPlan: currentPlan.info(),
                    expiredOn: expiredOn,
                    isAutoRenewing: isAutoRenewing,
                    originatingPlatform: {
                        switch originatingPlatform {
                            case .iOS: return .iOS
                            case .Android: return .Android
                        }
                    }()
                )
            case .expired:
                return .renew
            case .refunding(let originatingPlatform, let requestedAt):
                return .refund(
                    originatingPlatform: {
                        switch originatingPlatform {
                            case .iOS: return .iOS
                            case .Android: return .Android
                        }
                    }(),
                    requestedAt: requestedAt
                )
        }
    }
}

