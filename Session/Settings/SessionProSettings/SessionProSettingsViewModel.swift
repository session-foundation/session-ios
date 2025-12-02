// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SwiftUI
import Lucide
import GRDB
import DifferenceKit
import SessionUIKit
import SignalUtilitiesKit
import SessionNetworkingKit
import SessionMessagingKit
import SessionUtilitiesKit

// MARK: - Log.Category

public extension Log.Category {
    static let proSettingsViewModel: Log.Category = .create("ProSettingsViewModel", defaultLevel: .warn)
}

// MARK: - SessionProSettingsViewModel

public class SessionProSettingsViewModel: SessionListScreenContent.ViewModelType, NavigatableStateHolder {
    public let dependencies: Dependencies
    public let navigatableState: NavigatableState = NavigatableState()
    public let title: String = ""
    public let state: SessionListScreenContent.ListItemDataState<Section, ListItem> = SessionListScreenContent.ListItemDataState()
    
    /// This value is the current state of the view
    @MainActor @Published private(set) var internalState: State
    private var observationTask: Task<Void, Never>?
    
    // MARK: - Initialization
    
    @MainActor init(
        using dependencies: Dependencies
    ) {
        self.dependencies = dependencies
        self.internalState = State.initialState(using: dependencies)
        
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
                case .proStats:
                    return .titleWithTooltips(
                        info: .init(
                            id: "SessionListScreen.SectionHeader.ToolTip", // stringlint:ignore
                            content: "proStatsTooltip"
                                .put(key: "pro", value: Constants.pro)
                                .localizedFormatted(),
                            tintColor: .textSecondary,
                            position: .topRight
                        )
                    )
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
        case continueButton
        
        case proStats
        
        case updatePlan
        case refundRequested
        case renewPlan
        case recoverPlan
        case proBadge
        
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
    
    public struct State: ObservableKeyProvider {
        let profile: Profile
        let proState: SessionPro.State
        let numberOfGroupsUpgraded: Int
        let numberOfPinnedConversations: Int
        let numberOfProBadgesSent: Int
        let numberOfLongerMessagesSent: Int
        
        @MainActor public func sections(viewModel: SessionProSettingsViewModel, previousState: State) -> [SectionModel] {
            SessionProSettingsViewModel.sections(
                state: self,
                previousState: previousState,
                viewModel: viewModel
            )
        }
        
        /// We need `dependencies` to generate the keys in this case so set the variable `observedKeys` to an empty array to
        /// suppress the conformance warning
        public let observedKeys: Set<ObservableKey> = []
        public func observedKeys(using dependencies: Dependencies) -> Set<ObservableKey> {
            let sessionProManager: SessionProManagerType = dependencies[singleton: .sessionProManager]
            
            return [
                .anyConversationPinnedPriorityChanged,
                .profile(profile.id),
                .currentUserProState(sessionProManager),
                .setting(.groupsUpgradedCounter),
                .setting(.proBadgesSentCounter),
                .setting(.longerMessagesSentCounter)
            ]
        }
        
        static func initialState(using dependencies: Dependencies) -> State {
            return State(
                profile: dependencies.mutate(cache: .libSession) { $0.profile },
                proState: dependencies[singleton: .sessionProManager].currentUserCurrentProState,
                numberOfGroupsUpgraded: 0,
                numberOfPinnedConversations: 0,
                numberOfProBadgesSent: 0,
                numberOfLongerMessagesSent: 0
            )
        }
    }
    
    @Sendable private static func queryState(
        previousState: State,
        events: [ObservedEvent],
        isInitialQuery: Bool,
        using dependencies: Dependencies
    ) async -> State {
        var profile: Profile = previousState.profile
        var proState: SessionPro.State = previousState.proState
        var numberOfGroupsUpgraded: Int = previousState.numberOfGroupsUpgraded
        var numberOfPinnedConversations: Int = previousState.numberOfPinnedConversations
        var numberOfProBadgesSent: Int = previousState.numberOfProBadgesSent
        var numberOfLongerMessagesSent: Int = previousState.numberOfLongerMessagesSent
        
        /// Store a local copy of the events so we can manipulate it based on the state changes
        let eventsToProcess: [ObservedEvent] = events
        
        /// If we have no previous state then we need to fetch the initial state
        if isInitialQuery {
            do {
                proState = await dependencies[singleton: .sessionProManager].state
                    .first(defaultValue: .invalid)
                
                try await dependencies[singleton: .storage].readAsync { db in
                    numberOfGroupsUpgraded = (db[.groupsUpgradedCounter] ?? 0)
                    numberOfPinnedConversations = (
                        try? SessionThread
                            .filter(SessionThread.Columns.pinnedPriority > 0)
                            .fetchCount(db)
                    ).defaulting(to: 0)
                    numberOfProBadgesSent = (db[.proBadgesSentCounter] ?? 0)
                    numberOfLongerMessagesSent = (db[.longerMessagesSentCounter] ?? 0)
                }
            }
            catch {
                Log.critical(.proSettingsViewModel, "Failed to fetch initial state, due to error: \(error)")
            }
        }
        
        /// Split the events between those that need database access and those that don't
        let changes: EventChangeset = eventsToProcess.split(by: { $0.dataRequirement })
        
        /// Process any general event changes
        if let value = changes.latest(.currentUserProState, as: SessionPro.State.self) {
            proState = value
        }
        
        changes.forEach(.profile, as: ProfileEvent.self) { event in
            switch event.change {
                case .name(let name): profile = profile.with(name: name)
                case .nickname(let nickname): profile = profile.with(nickname: .set(to: nickname))
                case .displayPictureUrl(let url): profile = profile.with(displayPictureUrl: .set(to: url))
                case .proStatus(_, let features, let expiryUnixTimestampMs, let genIndexHashHex):
                    profile = profile.with(
                        proFeatures: .set(to: features),
                        proExpiryUnixTimestampMs: .set(to: expiryUnixTimestampMs),
                        proGenIndexHashHex: .set(to: genIndexHashHex)
                    )
                default: break
            }
        }
        
        changes.forEachEvent(.setting, as: Int.self) { event, value in
            switch event.key {
                case .setting(.groupsUpgradedCounter): numberOfGroupsUpgraded = value
                case .setting(.proBadgesSentCounter): numberOfProBadgesSent = value
                case .setting(.longerMessagesSentCounter): numberOfLongerMessagesSent = value
                default: break
            }
        }
        
        /// Then handle database events
        if !dependencies[singleton: .storage].isSuspended, !changes.databaseEvents.isEmpty {
            do {
                try await dependencies[singleton: .storage].readAsync { db in
                    if changes.latest(.anyConversationPinnedPriorityChanged) != nil {
                        numberOfPinnedConversations = (
                            try? SessionThread
                                .filter(SessionThread.Columns.pinnedPriority > 0)
                                .fetchCount(db)
                        ).defaulting(to: 0)
                    }
                }
            } catch {
                let eventList: String = changes.databaseEvents.map { $0.key.rawValue }.joined(separator: ", ")
                Log.critical(.proSettingsViewModel, "Failed to fetch state for events [\(eventList)], due to error: \(error)")
            }
        }
        else if !changes.databaseEvents.isEmpty {
            Log.warn(.proSettingsViewModel, "Ignored \(changes.databaseEvents.count) database event(s) sent while storage was suspended.")
        }
        
        return State(
            profile: profile,
            proState: proState,
            numberOfGroupsUpgraded: numberOfGroupsUpgraded,
            numberOfPinnedConversations: numberOfPinnedConversations,
            numberOfProBadgesSent: numberOfProBadgesSent,
            numberOfLongerMessagesSent: numberOfLongerMessagesSent
        )
    }
    
    private static func sections(
        state: State,
        previousState: State,
        viewModel: SessionProSettingsViewModel
    ) -> [SectionModel] {
        var logo: SectionModel = SectionModel(
            model: .logoWithPro,
            elements: [
                SessionListScreenContent.ListItemInfo(
                    id: .logoWithPro,
                    variant: .logoWithPro(
                        info: ListItemLogoWithPro.Info(
                            style:{
                                switch state.proState.status {
                                    case .expired: .disabled
                                    default: .normal
                                }
                            }(),
                            state: {
                                guard state.proState.status != .neverBeenPro else {
                                    return .success(
                                        description: "proFullestPotential"
                                            .put(key: "app_name", value: Constants.app_name)
                                            .put(key: "app_pro", value: Constants.app_pro)
                                            .localizedFormatted()
                                    )
                                }
                                
                                switch state.proState.loadingState {
                                    case .success: return .success(description: nil)
                                    case .loading:
                                        return .loading(
                                            message: {
                                                switch state.proState.status {
                                                    case .expired:
                                                        "checkingProStatus"
                                                            .put(key: "pro", value: Constants.pro)
                                                            .localized()
                                                    
                                                    default:
                                                        "proStatusLoading"
                                                            .put(key: "pro", value: Constants.pro)
                                                            .localized()
                                                }
                                            }()
                                        )
                                    
                                    case .error:
                                        return .error(
                                            message: {
                                                switch state.proState.status {
                                                    case .expired:
                                                        "errorCheckingProStatus"
                                                            .put(key: "pro", value: Constants.pro)
                                                            .localized()
                                                    
                                                    default:
                                                        "proErrorRefreshingStatus"
                                                            .put(key: "pro", value: Constants.pro)
                                                            .localized()
                                                }
                                            }()
                                        )
                                }
                            }()
                        )
                    ),
                    onTap: { [weak viewModel] in
                        guard state.proState.status != .neverBeenPro else { return }
                        
                        switch state.proState.loadingState {
                            case .success: break
                            case .loading:
                                viewModel?.showLoadingModal(
                                    from: .logoWithPro,
                                    title: {
                                        switch state.proState.status {
                                            case .active, .neverBeenPro:
                                                "proStatusLoading"
                                                    .put(key: "pro", value: Constants.pro)
                                                    .localized()
                                            
                                            case .expired:
                                                "checkingProStatus"
                                                    .put(key: "pro", value: Constants.pro)
                                                    .localized()
                                        }
                                    }(),
                                    description: {
                                        switch state.proState.status {
                                            case .active, .neverBeenPro:
                                                "proStatusLoadingDescription"
                                                    .put(key: "pro", value: Constants.pro)
                                                    .localized()
                                            
                                            case .expired:
                                                "checkingProStatusDescription"
                                                    .put(key: "pro", value: Constants.pro)
                                                    .localized()
                                        }
                                    }()
                                )
                            
                            case .error:
                                viewModel?.showErrorModal(
                                    from: .logoWithPro,
                                    title: "proStatusError"
                                        .put(key: "pro", value: Constants.pro)
                                        .localized(),
                                    description: "proStatusRefreshNetworkError"
                                        .put(key: "pro", value: Constants.pro)
                                        .localizedFormatted()
                                )
                        }
                    }
                )
            ]
        )
        
        switch state.proState.status {
            case .active, .expired: break
            case .neverBeenPro:
                logo.elements.append(
                    SessionListScreenContent.ListItemInfo(
                        id: .continueButton,
                        variant: .button(title: "theContinue".localized()),
                        onTap: { [weak viewModel] in viewModel?.updateProPlan(state: state) }
                    )
                )
        }
        
        let proStats: SectionModel = SectionModel(
            model: .proStats,
            elements: [
                SessionListScreenContent.ListItemInfo(
                    id: .proStats,
                    variant: .dataMatrix(
                        info: [
                            [
                                ListItemDataMatrix.Info(
                                    leadingAccessory: .icon(
                                        .messageSquare,
                                        size: .large,
                                        customTint: .primary
                                    ),
                                    title: SessionListScreenContent.TextInfo(
                                        "proLongerMessagesSent"
                                            .putNumber(state.numberOfLongerMessagesSent)
                                            .put(key: "total", value: state.proState.loadingState == .loading ? "" : state.numberOfLongerMessagesSent)
                                            .localized(),
                                        font: .Headings.H9
                                    ),
                                    isLoading: state.proState.loadingState == .loading
                                ),
                                ListItemDataMatrix.Info(
                                    leadingAccessory: .icon(
                                        .pin,
                                        size: .large,
                                        customTint: .primary
                                    ),
                                    title: SessionListScreenContent.TextInfo(
                                        "proPinnedConversations"
                                            .putNumber(state.numberOfPinnedConversations)
                                            .put(key: "total", value: state.proState.loadingState == .loading ? "" : state.numberOfPinnedConversations)
                                            .localized(),
                                        font: .Headings.H9
                                    ),
                                    isLoading: state.proState.loadingState == .loading
                                )
                            ],
                            [
                                ListItemDataMatrix.Info(
                                    leadingAccessory: .icon(
                                        .rectangleEllipsis,
                                        size: .large,
                                        customTint: .primary
                                    ),
                                    title: SessionListScreenContent.TextInfo(
                                        "proBadgesSent"
                                            .putNumber(state.numberOfProBadgesSent)
                                            .put(key: "total", value: state.proState.loadingState == .loading ? "" : state.numberOfProBadgesSent)
                                            .put(key: "pro", value: Constants.pro)
                                            .localized(),
                                        font: .Headings.H9
                                    ),
                                    isLoading: state.proState.loadingState == .loading
                                ),
                                ListItemDataMatrix.Info(
                                    leadingAccessory: .icon(
                                        UIImage(named: "ic_user_group"),
                                        size: .large,
                                        customTint: .disabled
                                    ),
                                    title: SessionListScreenContent.TextInfo(
                                        "proGroupsUpgraded"
                                            .putNumber(state.numberOfGroupsUpgraded)
                                            .put(key: "total", value: state.proState.loadingState == .loading ? "" : state.numberOfGroupsUpgraded)
                                            .localized(),
                                        font: .Headings.H9,
                                        color: state.proState.loadingState == .loading ? .textPrimary : .disabled
                                    ),
                                    tooltipInfo: SessionListScreenContent.TooltipInfo(
                                        id: "SessionListScreen.DataMatrix.UpgradedGroups.ToolTip", // stringlint:ignore
                                        content: "proLargerGroupsTooltip"
                                            .localizedFormatted(baseFont: .systemFont(ofSize: Values.smallFontSize)),
                                        tintColor: .disabled,
                                        position: .topLeft
                                    ),
                                    isLoading: state.proState.loadingState == .loading
                                )
                            ]
                        ]
                    ),
                    onTap: { [weak viewModel] in
                        guard state.proState.loadingState == .loading else { return }
                        
                        viewModel?.showLoadingModal(
                            from: .proStats,
                            title: "proStatsLoading"
                                .put(key: "pro", value: Constants.pro)
                                .localized(),
                            description: "proStatsLoadingDescription"
                                .put(key: "pro", value: Constants.pro)
                                .localized()
                        )
                    }
                )
            ]
        )
        
        let proSettings: SectionModel = SectionModel(
            model: .proSettings,
            elements: getProSettingsElements(state: state, previousState: previousState, viewModel: viewModel)
        )
        
        let proFeatures: SectionModel = SectionModel(
            model: .proFeatures,
            elements: ProFeaturesInfo.allCases(state.proState.status).map { info in
                SessionListScreenContent.ListItemInfo(
                    id: info.id,
                    variant: .cell(
                        info: ListItemCell.Info(
                            leadingAccessory: .icon(
                                info.icon,
                                iconSize: .medium,
                                customTint: .black,
                                gradientBackgroundColors: info.backgroundColors,
                                backgroundSize: .veryLarge,
                                backgroundCornerRadius: 8
                            ),
                            title: SessionListScreenContent.TextInfo(
                                info.title,
                                font: .Headings.H9,
                                accessory: info.accessory
                            ),
                            description: SessionListScreenContent.TextInfo(
                                info.description,
                                font: .Body.smallRegular,
                                color: .textSecondary
                            )
                        )
                    )
                )
            }.appending(
                SessionListScreenContent.ListItemInfo(
                    id: .plusLoadsMore,
                    variant: .cell(
                        info: ListItemCell.Info(
                            leadingAccessory: .icon(
                                Lucide.image(icon: .circlePlus, size: IconSize.medium.size),
                                iconSize: .medium,
                                customTint: .black,
                                gradientBackgroundColors: {
                                    return switch state.proState.status {
                                        case .expired: [ThemeValue.disabled]
                                        default: [.explicitPrimary(.orange), .explicitPrimary(.yellow)]
                                    }
                                }(),
                                backgroundSize: .veryLarge,
                                backgroundCornerRadius: 8
                            ),
                            title: SessionListScreenContent.TextInfo(
                                "plusLoadsMore".localized(),
                                font: .Headings.H9
                            ),
                            description: SessionListScreenContent.TextInfo(
                                font: .Body.smallRegular,
                                attributedString: "plusLoadsMoreDescription"
                                    .put(key: "pro", value: Constants.pro)
                                    .put(key: "icon", value: Lucide.Icon.squareArrowUpRight)
                                    .localizedFormatted(Fonts.Body.smallRegular),
                                color: .textSecondary
                            )
                        )
                    ),
                    onTap: { [weak viewModel] in viewModel?.openUrl(Constants.urls.proRoadmap) }
                )
            )
        )
        
        let proManagement: SectionModel = SectionModel(
            model: .proManagement,
            elements: getProManagementElements(state: state, viewModel: viewModel)
        )
        
        let help: SectionModel = SectionModel(
            model: .help,
            elements: [
                SessionListScreenContent.ListItemInfo(
                    id: .faq,
                    variant: .cell(
                        info: .init(
                            title: .init(
                                "proFaq"
                                    .put(key: "pro", value: Constants.pro)
                                    .localized(),
                                font: .Headings.H8
                            ),
                            description: .init(
                                "proFaqDescription"
                                    .put(key: "app_pro", value: Constants.app_pro)
                                    .localized(),
                                font: .Body.smallRegular
                            ),
                            trailingAccessory: .icon(
                                .squareArrowUpRight,
                                size: .large,
                                customTint: {
                                    switch state.proState.status {
                                        case .expired: return .textPrimary
                                        default: return .sessionButton_text
                                    }
                                }()
                            )
                        )
                    ),
                    onTap: { [weak viewModel] in viewModel?.openUrl(Constants.urls.proFaq) }
                ),
                SessionListScreenContent.ListItemInfo(
                    id: .support,
                    variant: .cell(
                        info: .init(
                            title: .init(
                                "helpSupport".localized(),
                                font: .Headings.H8
                            ),
                            description: .init(
                                "proSupportDescription"
                                    .put(key: "pro", value: Constants.pro)
                                    .localized(),
                                font: .Body.smallRegular
                            ),
                            trailingAccessory: .icon(
                                .squareArrowUpRight,
                                size: .large,
                                customTint: {
                                    switch state.proState.status {
                                        case .expired: return .textPrimary
                                        default: return .sessionButton_text
                                    }
                                }()
                            )
                        )
                    ),
                    onTap: { [weak viewModel] in viewModel?.openUrl(Constants.urls.support) }
                )
            ]
        )
        
        return switch (state.proState.status, state.proState.refundingStatus) {
            case (.neverBeenPro, _): [ logo, proFeatures, help ]
            case (.active, .notRefunding): [ logo, proStats, proSettings, proFeatures, proManagement, help ]
            case (.expired, _): [ logo, proManagement, proFeatures, help ]
            case (.active, .refunding): [ logo, proStats, proSettings, proFeatures, help ]
        }
    }
    
    // MARK: - Pro Settings Elements
    
    private static func getProSettingsElements(
        state: State,
        previousState: State,
        viewModel: SessionProSettingsViewModel
    ) -> [SessionListScreenContent.ListItemInfo<ListItem>] {
        let initialProSettingsElements: [SessionListScreenContent.ListItemInfo<ListItem>]
        
        switch (state.proState.status, state.proState.refundingStatus) {
            case (.neverBeenPro, _), (.expired, _): initialProSettingsElements = []
            case (.active, .notRefunding):
                initialProSettingsElements = [
                    SessionListScreenContent.ListItemInfo(
                        id: .updatePlan,
                        variant: .cell(
                            info: ListItemCell.Info(
                                title: SessionListScreenContent.TextInfo(
                                    "updateAccess"
                                        .put(key: "pro", value: Constants.pro)
                                        .localized(),
                                    font: .Headings.H8
                                ),
                                description: {
                                    switch state.proState.loadingState {
                                        case .loading:
                                            return SessionListScreenContent.TextInfo(
                                                font: .Body.smallRegular,
                                                attributedString: "proAccessLoadingEllipsis"
                                                    .put(key: "pro", value: Constants.pro)
                                                    .localizedFormatted(Fonts.Body.smallRegular)
                                            )
                                        
                                        case .error:
                                            return SessionListScreenContent.TextInfo(
                                                font: .Body.smallRegular,
                                                attributedString: "errorLoadingProAccess"
                                                    .put(key: "pro", value: Constants.pro)
                                                    .localizedFormatted(Fonts.Body.smallRegular),
                                                color: .warning
                                            )
                                        
                                        case .success:
                                            let expirationDate: Date = Date(
                                                timeIntervalSince1970: floor(Double(state.proState.accessExpiryTimestampMs ?? 0) / 1000)
                                            )
                                            let expirationString: String = expirationDate
                                                .timeIntervalSince(viewModel.dependencies.dateNow)
                                                .ceilingFormatted(
                                                    format: .long,
                                                    allowedUnits: [.day, .hour, .minute]
                                                )
                                            
                                            return SessionListScreenContent.TextInfo(
                                                font: .Body.smallRegular,
                                                attributedString: (
                                                    state.proState.autoRenewing == true ?
                                                        "proAutoRenewTime"
                                                            .put(key: "pro", value: Constants.pro)
                                                            .put(key: "time", value: expirationString)
                                                            .localizedFormatted(Fonts.Body.smallRegular) :
                                                        "proExpiringTime"
                                                            .put(key: "pro", value: Constants.pro)
                                                            .put(key: "time", value: expirationString)
                                                            .localizedFormatted(Fonts.Body.smallRegular)
                                                )
                                            )
                                    }
                                }(),
                                trailingAccessory: state.proState.loadingState == .loading ? .loadingIndicator(size: .large) : .icon(.chevronRight, size: .large)
                            )
                        ),
                        onTap: { [weak viewModel] in
                            switch state.proState.loadingState {
                                case .success: viewModel?.updateProPlan(state: state)
                                case .loading:
                                    viewModel?.showLoadingModal(
                                        from: .updatePlan,
                                        title: "proAccessLoading"
                                            .put(key: "pro", value: Constants.pro)
                                            .localized(),
                                        description: "proAccessLoadingDescription"
                                            .put(key: "pro", value: Constants.pro)
                                            .localized()
                                    )
                                
                                case .error:
                                    viewModel?.showErrorModal(
                                        from: .updatePlan,
                                        title: "proAccessError"
                                            .put(key: "pro", value: Constants.pro)
                                            .localized(),
                                        description: "proAccessNetworkLoadError"
                                            .put(key: "pro", value: Constants.pro)
                                            .put(key: "app_name", value: Constants.app_name)
                                            .localizedFormatted(baseFont: .systemFont(ofSize: Values.smallFontSize))
                                    )
                            }
                        }
                    )
                ]
            
            case (.active, .refunding):
                initialProSettingsElements = [
                    SessionListScreenContent.ListItemInfo(
                        id: .refundRequested,
                        variant: .cell(
                            info: ListItemCell.Info(
                                title: SessionListScreenContent.TextInfo(
                                    "proRequestedRefund".localized(),
                                    font: .Headings.H8
                                ),
                                description: SessionListScreenContent.TextInfo(
                                    font: .Body.smallRegular,
                                    attributedString: "processingRefundRequest"
                                        .put(key: "platform", value: state.proState.originatingPlatform.platform)
                                        .localizedFormatted(Fonts.Body.smallRegular)
                                ),
                                trailingAccessory: .icon(.circleAlert, size: .large)
                            )
                        ),
                        onTap: { [weak viewModel] in
                            switch state.proState.loadingState {
                                case .success: viewModel?.updateProPlan(state: state)
                                case .loading:
                                    viewModel?.showLoadingModal(
                                        from: .updatePlan,
                                        title: "proAccessLoading"
                                            .put(key: "pro", value: Constants.pro)
                                            .localized(),
                                        description: "proAccessLoadingDescription"
                                            .put(key: "pro", value: Constants.pro)
                                            .localized()
                                    )
                                
                                case .error:
                                    viewModel?.showErrorModal(
                                        from: .updatePlan,
                                        title: "proAccessError"
                                            .put(key: "pro", value: Constants.pro)
                                            .localized(),
                                        description: "proAccessNetworkLoadError"
                                            .put(key: "pro", value: Constants.pro)
                                            .put(key: "app_name", value: Constants.app_name)
                                            .localizedFormatted(baseFont: .systemFont(ofSize: Values.smallFontSize))
                                    )
                            }
                        }
                    )
                ]
        }
        
        return initialProSettingsElements + [
            SessionListScreenContent.ListItemInfo(
                id: .proBadge,
                variant: .cell(
                    info: ListItemCell.Info(
                        title: SessionListScreenContent.TextInfo(
                            "proBadge"
                                .put(key: "pro", value: Constants.pro)
                                .localized(),
                            font: .Headings.H8
                        ),
                        description: SessionListScreenContent.TextInfo(
                            "proBadgeVisible"
                                .put(key: "app_pro", value: Constants.app_pro)
                                .localized(),
                            font: .Body.smallRegular
                        ),
                        trailingAccessory: .toggle(
                            state.profile.proFeatures.contains(.proBadge),
                            oldValue: previousState.profile.proFeatures.contains(.proBadge)
                        )
                    )
                ),
                onTap: { [dependencies = viewModel.dependencies] in
                    Task.detached(priority: .userInitiated) {
                        try? await Profile.updateLocal(
                            proFeatures: (state.profile.proFeatures.contains(.proBadge) ?
                                state.profile.proFeatures.removing(.proBadge) :
                                state.profile.proFeatures.inserting(.proBadge)
                            ),
                            using: dependencies
                        )
                    }
                }
            )
        ]
    }
    
    // MARK: - Pro Management Elements
    
    private static func getProManagementElements(
        state: State,
        viewModel: SessionProSettingsViewModel
    ) -> [SessionListScreenContent.ListItemInfo<ListItem>] {
        switch (state.proState.status, state.proState.refundingStatus) {
            case (.neverBeenPro, _), (.active, .refunding): return []
            case (.active, .notRefunding):
                var renewingItems: [SessionListScreenContent.ListItemInfo<ListItem>] = []
                
                if state.proState.autoRenewing == true {
                    renewingItems.append(
                        SessionListScreenContent.ListItemInfo(
                            id: .cancelPlan,
                            variant: .cell(
                                info: ListItemCell.Info(
                                    title: SessionListScreenContent.TextInfo(
                                        "cancelAccess"
                                            .put(key: "pro", value: Constants.pro)
                                            .localized(),
                                        font: .Headings.H8,
                                        color: .danger
                                    ),
                                    trailingAccessory: .icon(.circleX, size: .large, customTint: .danger)
                                )
                            ),
                            onTap: { [weak viewModel] in viewModel?.cancelPlan(state: state) }
                        )
                    )
                }
                
                return renewingItems + [
                    SessionListScreenContent.ListItemInfo(
                        id: .requestRefund,
                        variant: .cell(
                            info: ListItemCell.Info(
                                title: SessionListScreenContent.TextInfo(
                                    "requestRefund".localized(),
                                    font: .Headings.H8,
                                    color: .danger
                                ),
                                trailingAccessory: .icon(.circleAlert, size: .large, customTint: .danger)
                            )
                        ),
                        onTap: { [weak viewModel] in viewModel?.requestRefund(state: state) }
                    )
                ]
            
            case (.expired, _):
                return [
                    SessionListScreenContent.ListItemInfo(
                        id: .renewPlan,
                        variant: .cell(
                            info: ListItemCell.Info(
                                title: SessionListScreenContent.TextInfo(
                                    "proAccessRenew"
                                        .put(key: "pro", value: Constants.pro)
                                        .localized(),
                                    font: .Headings.H8,
                                    color: state.proState.loadingState == .success ? .primary : .textPrimary
                                ),
                                description: {
                                    switch state.proState.loadingState {
                                        case .success: return nil
                                        case .error:
                                            return SessionListScreenContent.TextInfo(
                                                font: .Body.smallRegular,
                                                attributedString: "errorCheckingProStatus"
                                                    .put(key: "pro", value: Constants.pro)
                                                    .localizedFormatted(Fonts.Body.smallRegular),
                                                color: .warning
                                            )
                                        
                                        case .loading:
                                            return SessionListScreenContent.TextInfo(
                                                font: .Body.smallRegular,
                                                attributedString: "checkingProStatusEllipsis"
                                                    .put(key: "pro", value: Constants.pro)
                                                    .localizedFormatted(Fonts.Body.smallRegular),
                                                color: .textPrimary
                                            )
                                    }
                                }(),
                                trailingAccessory: (
                                    state.proState.loadingState == .loading ?
                                        .loadingIndicator(size: .large) :
                                        .icon(
                                            .circlePlus,
                                            size: .large,
                                            customTint: state.proState.loadingState == .success ? .primary : .textPrimary
                                        )
                                )
                            )
                        ),
                        onTap: { [weak viewModel] in
                            switch state.proState.loadingState {
                                case .success: viewModel?.updateProPlan(state: state)
                                case .loading:
                                    viewModel?.showLoadingModal(
                                        from: .renewPlan,
                                        title: "checkingProStatus"
                                            .put(key: "pro", value: Constants.pro)
                                            .localized(),
                                        description: "checkingProStatusRenew"
                                            .put(key: "pro", value: Constants.pro)
                                            .localized()
                                    )
                                
                                case .error:
                                    viewModel?.showErrorModal(
                                        from: .updatePlan,
                                        title: "proAccessError"
                                            .put(key: "pro", value: Constants.pro)
                                            .localized(),
                                        description: "proAccessNetworkLoadError"
                                            .put(key: "pro", value: Constants.pro)
                                            .put(key: "app_name", value: Constants.app_name)
                                            .localizedFormatted(baseFont: .systemFont(ofSize: Values.smallFontSize))
                                    )
                            }
                        }
                    ),
                    SessionListScreenContent.ListItemInfo(
                        id: .recoverPlan,
                        variant: .cell(
                            info: ListItemCell.Info(
                                title: SessionListScreenContent.TextInfo(
                                    "proAccessRecover"
                                        .put(key: "pro", value: Constants.pro)
                                        .localized(),
                                    font: .Headings.H8,
                                    color: .textPrimary
                                ),
                                trailingAccessory: .icon(
                                    .refreshCcw,
                                    size: .large,
                                    customTint: .textPrimary
                                )
                            )
                        ),
                        onTap: { [weak viewModel] in viewModel?.recoverProPlan() }
                    ),
                ]
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
    
    func showLoadingModal(
        from item: ListItem,
        title: String,
        description: String
    ) {
        guard [ .logoWithPro, .updatePlan, .proStats, .renewPlan ].contains(item) else { return }
        
        let modal: ConfirmationModal = ConfirmationModal(
            info: ConfirmationModal.Info(
                title: title,
                body: .text(description, scrollMode: .never),
                cancelTitle: "okay".localized(),
                cancelStyle: .alert_text
            )
        )
        
        self.transitionToScreen(modal, transitionType: .present)
    }
    
    func showErrorModal(
        from item: ListItem,
        title: String,
        description: ThemedAttributedString
    ) {
        guard [ .logoWithPro, .updatePlan, .renewPlan ].contains(item) else { return }
        
        let modal: ConfirmationModal = ConfirmationModal(
            info: ConfirmationModal.Info(
                title: title,
                body: .attributedText(description, scrollMode: .never),
                confirmTitle: "retry".localized(),
                confirmStyle: .alert_text,
                cancelTitle: "helpSupport".localized(),
                cancelStyle: .alert_text,
                onConfirm:  { [dependencies] _ in
                    Task.detached(priority: .userInitiated) {
                        try? await dependencies[singleton: .sessionProManager].refreshProState()
                    }
                },
                onCancel: { [weak self] _ in self?.openUrl(Constants.urls.support) }
            )
        )
        
        self.transitionToScreen(modal, transitionType: .present)
    }
    
    @MainActor func updateProPlan(state: State) {
        guard state.proState.buildVariant != .ipa else {
            let viewController = ModalActivityIndicatorViewController() { [weak self] modalActivityIndicator in
                Task {
                    sleep(5)
                    modalActivityIndicator.dismiss(animated: true) {
                        self?.showToast(text: "errorGeneric".localized())
                    }
                }
            }
            self.transitionToScreen(viewController, transitionType: .present)
            return
        }
        
        let viewController: SessionHostingViewController = SessionHostingViewController(
            rootView: SessionProPaymentScreen(
                viewModel: SessionProPaymentScreenContent.ViewModel(
                    dataModel: SessionProPaymentScreenContent.DataModel(
                        flow: SessionProPaymentScreenContent.SessionProPlanPaymentFlow(state: state.proState),
                        plans: state.proState.plans.map { SessionProPaymentScreenContent.SessionProPlanInfo(plan: $0) }
                    ),
                    dependencies: dependencies
                )
            )
        )
        self.transitionToScreen(viewController)
    }
    
    @MainActor func recoverProPlan() {
        Task.detached(priority: .userInitiated) { [weak self, manager = dependencies[singleton: .sessionProManager]] in
            try? await manager.refreshProState()
            
            let state: SessionPro.State = manager.currentUserCurrentProState
            
            await MainActor.run { [weak self] in
                let modal: ConfirmationModal = ConfirmationModal(
                    info: ConfirmationModal.Info(
                        title: {
                            switch state.status {
                                case .active:
                                    return "proAccessRestored"
                                        .put(key: "pro", value: Constants.pro)
                                        .localized()
                                    
                                case .neverBeenPro, .expired:
                                    return "proAccessNotFound"
                                        .put(key: "pro", value: Constants.pro)
                                        .localized()
                            }
                        }(),
                        body: {
                            switch state.status {
                                case .active:
                                    return .text(
                                        "proAccessRestoredDescription"
                                            .put(key: "app_name", value: Constants.app_name)
                                            .put(key: "pro", value: Constants.pro)
                                            .localized(),
                                        scrollMode: .never
                                    )
                                    
                                case .neverBeenPro, .expired:
                                    return .text(
                                        "proAccessNotFoundDescription"
                                            .put(key: "app_name", value: Constants.app_name)
                                            .put(key: "pro", value: Constants.pro)
                                            .localized(),
                                        scrollMode: .never
                                    )
                            }
                        }(),
                        confirmTitle: (state.status == .active ? nil : "helpSupport".localized()),
                        cancelTitle: (state.status == .active ? "okay".localized() : "close".localized()),
                        cancelStyle: (state.status == .active ? .textPrimary : .danger),
                        dismissOnConfirm: false,
                        onConfirm: { [weak self] modal in
                            guard state.status != .active else {
                                return modal.dismiss(animated: true)
                            }
                            
                            self?.openUrl(Constants.urls.proAccessNotFound)
                        }
                    )
                )
                    
                self?.transitionToScreen(modal, transitionType: .present)
            }
        }
    }
    
    func cancelPlan(state: State) {
        let viewController: SessionHostingViewController = SessionHostingViewController(
            rootView: SessionProPaymentScreen(
                viewModel: SessionProPaymentScreenContent.ViewModel(
                    dataModel: SessionProPaymentScreenContent.DataModel(
                        flow: .cancel(originatingPlatform: state.proState.originatingPlatform),
                        plans: state.proState.plans.map { SessionProPaymentScreenContent.SessionProPlanInfo(plan: $0) }
                    ),
                    dependencies: dependencies
                )
            )
        )
        self.transitionToScreen(viewController)
    }
    
    func requestRefund(state: State) {
        let viewController: SessionHostingViewController = SessionHostingViewController(
            rootView: SessionProPaymentScreen(
                viewModel: SessionProPaymentScreenContent.ViewModel(
                    dataModel: SessionProPaymentScreenContent.DataModel(
                        flow: .refund(
                            originatingPlatform: state.proState.originatingPlatform,
                            isNonOriginatingAccount: (state.proState.originatingAccount == .nonOriginatingAccount),
                            requestedAt: nil
                        ),
                        plans: state.proState.plans.map { SessionProPaymentScreenContent.SessionProPlanInfo(plan: $0) }
                    ),
                    dependencies: dependencies
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
        
        static func allCases(_ state: Network.SessionPro.BackendUserProStatus?) -> [ProFeaturesInfo] {
            return [
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
                    id: .unlimitedPins,
                    icon: Lucide.image(icon: .pin, size: IconSize.medium.size),
                    backgroundColors: {
                        return switch state {
                            case .expired: [ThemeValue.disabled]
                            default: [.explicitPrimary(.purple), .explicitPrimary(.pink)]
                        }
                    }(),
                    title: "proUnlimitedPins".localized(),
                    description: "proUnlimitedPinsDescription".localized(),
                    accessory: .none
                ),
                ProFeaturesInfo(
                    id: .animatedDisplayPictures,
                    icon: Lucide.image(icon: .squarePlay, size: IconSize.medium.size),
                    backgroundColors: {
                        return switch state {
                            case .expired: [ThemeValue.disabled]
                            default: [.explicitPrimary(.pink), .explicitPrimary(.red)]
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
                            default: [.explicitPrimary(.red), .explicitPrimary(.orange)]
                        }
                    }(),
                    title: "proBadges".localized(),
                    description: "proBadgesDescription".put(key: "app_name", value: Constants.app_name).localized(),
                    accessory: .proBadgeLeading(
                        size: .mini,
                        themeBackgroundColor: {
                            return switch state {
                                case .expired: .disabled
                                default: .primary
                            }
                        }()
                    )
                )
            ]
        }
    }
}

// MARK: - Convenience

private extension ObservedEvent {
    var dataRequirement: EventDataRequirement {
        switch (key, key.generic) {
            case (.anyConversationPinnedPriorityChanged, _): return .databaseQuery
            default: return .other
        }
    }
}
