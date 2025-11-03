// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SessionUIKit
import SessionUtilitiesKit
import DifferenceKit

public class SessionProBottomSheetViewModel: SessionProBottomSheetViewModelType, SessionListScreenContent.NavigatableStateHolder {
    public let dependencies: Dependencies
    public let navigatableState: SessionListScreenContent.NavigatableState = .init()
    public var title: String = ""
    public var state: SessionListScreenContent.ListItemDataState<Section, ListItem> = SessionListScreenContent.ListItemDataState()
    
    /// This value is the current state of the view
    @MainActor @Published private(set) var internalState: ViewModelState
    private var observationTask: Task<Void, Never>?
    
    // MARK: - Initialization
    
    @MainActor init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.internalState = ViewModelState.initialState()
        
        self.observationTask = ObservationBuilder
            .initialValue(self.internalState)
            .debounce(for: .never)
            .using(dependencies: dependencies)
            .query(SessionProBottomSheetViewModel.queryState)
            .assign { [weak self] updatedState in
                guard let self = self else { return }
                
                self.state.updateTableData(updatedState.sections(viewModel: self))
                self.internalState = updatedState
            }
    }
    
    // MARK: - Config
    
    public enum Section: SessionListScreenContent.ListSection {
        case logoWithPro
        case proFeatures
        
        public var title: String? {
            switch self {
                case .proFeatures: return "proBetaFeatures".put(key: "pro", value: Constants.pro).localized()
                default: return nil
            }
        }
        
        public var style: SessionListScreenContent.ListSectionStyle {
            switch self {
                case .proFeatures: return .titleNoBackgroundContent
                default: return .none
            }
        }
        
        public var divider: Bool { false }
        public var footer: String? { return nil }
    }
    
    public enum ListItem: Differentiable {
        case logoWithPro
        case continueButton

        case longerMessages
        case unlimitedPins
        case animatedDisplayPictures
        case badges
        case plusLoadsMore
    }
    
    // MARK: - Content
    
    public struct ViewModelState: ObservableKeyProvider {
        let currentProPlanState: SessionProPlanState
        let loadingState: SessionProLoadingState
        
        @MainActor public func sections(viewModel: SessionProBottomSheetViewModel) -> [SectionModel] {
            SessionProBottomSheetViewModel.sections(
                state: self,
                viewModel: viewModel
            )
        }
        
        public let observedKeys: Set<ObservableKey> = [
            .feature(.mockCurrentUserSessionProState),          // TODO: real data from libSession
            .feature(.mockCurrentUserSessionProLoadingState)    // TODO: real loading status
        ]
        
        static func initialState() -> ViewModelState {
            return ViewModelState(
                currentProPlanState: .none,
                loadingState: .loading
            )
        }
    }
    
    @Sendable private static func queryState(
        previousState: ViewModelState,
        events: [ObservedEvent],
        isInitialQuery: Bool,
        using dependencies: Dependencies
    ) async -> ViewModelState {
        var currentProPlanState: SessionProPlanState = previousState.currentProPlanState
        var loadingState: SessionProLoadingState = previousState.loadingState
        
        currentProPlanState = dependencies[singleton: .sessionProState].sessionProStateSubject.value
        loadingState = dependencies[feature: .mockCurrentUserSessionProLoadingState]
        
        return ViewModelState(
            currentProPlanState: currentProPlanState,
            loadingState: loadingState
        )
    }
    
    private static func sections(
        state: ViewModelState,
        viewModel: SessionProBottomSheetViewModel
    ) -> [SectionModel] {
        let logo: SectionModel = SectionModel(
            model: .logoWithPro,
            elements: [
                SessionListScreenContent.ListItemInfo(
                    id: .logoWithPro,
                    variant: .logoWithPro(
                        info: .init(
                            style:.normal,
                            state: {
                                switch state.loadingState {
                                case .loading:
                                    return .loading(
                                        message: {
                                            if case .expired = state.currentProPlanState {
                                                return "proStatusLoading"
                                                    .put(key: "pro", value: Constants.pro)
                                                    .localized()
                                            } else {
                                                return "checkingProStatus"
                                                    .put(key: "pro", value: Constants.pro)
                                                    .localized()
                                            }
                                        }()
                                    )
                                case .error:
                                    return .error(
                                        message: {
                                            if case .expired = state.currentProPlanState {
                                                return "proErrorRefreshingStatus"
                                                    .put(key: "pro", value: Constants.pro)
                                                    .localized()
                                            } else {
                                                return "errorCheckingProStatus"
                                                    .put(key: "pro", value: Constants.pro)
                                                    .localized()
                                            }
                                        }()
                                    )
                                case .success:
                                    return .success
                                }
                            }(),
                            description: {
                                if case .expired = state.currentProPlanState {
                                    return "proAccessRenewStart"
                                        .put(key: "pro", value: Constants.pro)
                                        .put(key: "app_pro", value: Constants.app_pro)
                                        .localizedFormatted()
                                } else {
                                    return "proFullestPotential"
                                        .put(key: "app_name", value: Constants.app_name)
                                        .put(key: "app_pro", value: Constants.app_pro)
                                        .localizedFormatted()
                                }
                            }()
                        )
                    ),
                    onTap: { [weak viewModel] in
                        switch state.loadingState {
                        case .loading:
                            viewModel?.showLoadingModal(
                                title: "checkingProStatus"
                                    .put(key: "pro", value: Constants.pro)
                                    .localized(),
                                description: {
                                    if case .expired = state.currentProPlanState {
                                        return "checkingProStatusDescription"
                                            .put(key: "pro", value: Constants.pro)
                                            .localized()
                                    } else {
                                        return "checkingProStatusContinue"
                                            .put(key: "pro", value: Constants.pro)
                                            .localized()
                                    }
                                }()
                            )
                        case .error:
                            viewModel?.showErrorModal(
                                title: "proStatusError"
                                    .put(key: "pro", value: Constants.pro)
                                    .localized(),
                                description: "proStatusRefreshNetworkError"
                                    .put(key: "pro", value: Constants.pro)
                                    .localizedFormatted()
                            )
                        case .success:
                            break
                        }
                    }
                ),
                SessionListScreenContent.ListItemInfo(
                    id: .continueButton,
                    variant: .button(title: "theContinue".localized(), enabled: (state.loadingState == .success)),
                    onTap: { [weak viewModel] in
                        switch state.loadingState {
                        case .loading:
                            viewModel?.showLoadingModal(
                                title: "checkingProStatus"
                                    .put(key: "pro", value: Constants.pro)
                                    .localized(),
                                description: "checkingProStatusContinue"
                                    .put(key: "pro", value: Constants.pro)
                                    .localized()
                            )
                        case .error:
                            viewModel?.showErrorModal(
                                title: "proStatusError"
                                    .put(key: "pro", value: Constants.pro)
                                    .localized(),
                                description: "proStatusRefreshNetworkError"
                                    .put(key: "pro", value: Constants.pro)
                                    .localizedFormatted()
                            )
                        case .success:
                            viewModel?.updateProPlan()
                        }
                    }
                )
            ]
        )
        
        let proFeatures: SectionModel = SectionModel(
            model: .proFeatures,
            elements: getProFeaturesElements(state: state, viewModel: viewModel)
        )
        
        return [ logo, proFeatures ]
    }
    
    // MARK: - Pro Features Elements
    
    private static func getProFeaturesElements(
        state: ViewModelState,
        viewModel: SessionProBottomSheetViewModel
    ) -> [SessionListScreenContent.ListItemInfo<ListItem>] {
        let proFeaturesIds: [ListItem] = [ .longerMessages, .unlimitedPins, .animatedDisplayPictures, .badges ]
        let proFeatureInfos: [ProFeaturesInfo] = ProFeaturesInfo.allCases(proStateExpired: false)
        let plusMoreFeatureInfo: ProFeaturesInfo = ProFeaturesInfo.plusMoreFeatureInfo(proStateExpired: false)
        
        var result = zip(proFeaturesIds, proFeatureInfos).map { id, info in
            SessionListScreenContent.ListItemInfo(
                id: id,
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
                        description: .init(font: .Body.smallRegular, attributedString: info.description, color: .textSecondary)
                    )
                )
            )
        }
        result.append(
            SessionListScreenContent.ListItemInfo(
                id: .plusLoadsMore,
                variant: .cell(
                    info: .init(
                        leadingAccessory: .icon(
                            plusMoreFeatureInfo.icon,
                            iconSize: .medium,
                            customTint: .black,
                            gradientBackgroundColors: plusMoreFeatureInfo.backgroundColors,
                            backgroundSize: .veryLarge,
                            backgroundCornerRadius: 8
                        ),
                        title: .init(plusMoreFeatureInfo.title, font: .Headings.H9),
                        description: .init(
                            font: .Body.smallRegular,
                            attributedString: plusMoreFeatureInfo.description,
                            color: .textSecondary
                        )
                    )
                ),
                onTap: { [weak viewModel] in
                    viewModel?.openUrl(Constants.session_pro_roadmap)
                }
            )
        )
            
        return result
    }
    
    func updateProPlan() {
        self.transitionToScreen(
            SessionProPaymentScreen(
                viewModel: SessionProPaymentScreenContent.ViewModel(
                    dependencies: dependencies,
                    dataModel: .init(
                        flow: dependencies[singleton: .sessionProState].sessionProStateSubject.value.toPaymentFlow(),
                        plans: dependencies[singleton: .sessionProState].sessionProPlans.map { $0.info() }
                    )
                )
            ),
            transitionType: .push
        )
    }
    
    public func showLoadingModal(title: String, description: String) {
        
    }
    
    public func showErrorModal(title: String, description: ThemedAttributedString) {
        
    }
    
    public func openUrl(_ urlString: String) {
        
    }
}
