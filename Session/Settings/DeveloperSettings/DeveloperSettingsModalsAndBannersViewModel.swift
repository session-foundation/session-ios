// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import GRDB
import DifferenceKit
import SessionUIKit
import SessionNetworkingKit
import SessionMessagingKit
import SessionUtilitiesKit

class DeveloperSettingsModalsAndBannersViewModel: SessionTableViewModel, NavigatableStateHolder, ObservableTableSource {
    public let dependencies: Dependencies
    public let navigatableState: NavigatableState = NavigatableState()
    public let state: TableDataState<Section, TableItem> = TableDataState()
    public let observableState: ObservableTableSourceState<Section, TableItem> = ObservableTableSourceState()
    
    private var updatedCustomDateTime: String?
    
    /// This value is the current state of the view
    @MainActor @Published private(set) var internalState: State
    private var observationTask: Task<Void, Never>?
    
    // MARK: - Initialization
    
    @MainActor init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.internalState = State.initialState(using: dependencies)
        
        /// Bind the state
        self.observationTask = ObservationBuilder
            .initialValue(self.internalState)
            .debounce(for: .never)
            .using(dependencies: dependencies)
            .query(DeveloperSettingsModalsAndBannersViewModel.queryState)
            .assign { [weak self] updatedState in
                guard let self = self else { return }
                
                // FIXME: To slightly reduce the size of the changes this new observation mechanism is currently wired into the old SessionTableViewController observation mechanism, we should refactor it so everything uses the new mechanism
                let oldState: State = self.internalState
                self.internalState = updatedState
                self.pendingTableDataSubject.send(updatedState.sections(viewModel: self, previousState: oldState))
            }
    }
    
    // MARK: - Config
    
    public enum Section: SessionTableSection {
        case donations
        case appReview
        case versionDeprecation
        
        var title: String? {
            switch self {
                case .donations: return "Donations"
                case .appReview: return "App Review"
                case .versionDeprecation: return "Version Deprecation"
            }
        }
        
        var style: SessionTableSectionStyle {
            switch self {
                case .donations: return .titleRoundedContent
                case .appReview: return .titleRoundedContent
                case .versionDeprecation: return .titleRoundedContent
            }
        }
    }
    
    public enum TableItem: Hashable, Differentiable, CaseIterable {
        case showDonationsCTAModal
        case donationsCTAModalAppearanceCount
        case customFirstInstallDateTime
        case donationsUrlOpenCount
        case donationsUrlCopyCount
        
        case resetAppReviewPrompt
        case simulateAppReviewLimit
        
        case versionDeprecationWarning
        case versionDeprecationMinimum
        
        // MARK: - Conformance
        
        public typealias DifferenceIdentifier = String
        
        public var differenceIdentifier: String {
            switch self {
                case .showDonationsCTAModal: return "showDonationsCTAModal"
                case .donationsCTAModalAppearanceCount: return "donationsCTAModalAppearanceCount"
                case .customFirstInstallDateTime: return "customFirstInstallDateTime"
                case .donationsUrlOpenCount: return "donationsUrlOpenCount"
                case .donationsUrlCopyCount: return "donationsUrlCopyCount"
                case .resetAppReviewPrompt: return "resetAppReviewPrompt"
                case .simulateAppReviewLimit: return "simulateAppReviewLimit"
                case .versionDeprecationWarning: return "versionDeprecationWarning"
                case .versionDeprecationMinimum: return "versionDeprecationMinimum"
            }
        }
        
        public func isContentEqual(to source: TableItem) -> Bool {
            self.differenceIdentifier == source.differenceIdentifier
        }
        
        public static var allCases: [TableItem] {
            var result: [TableItem] = []
            switch TableItem.showDonationsCTAModal {
                case .showDonationsCTAModal: result.append(.showDonationsCTAModal); fallthrough
                case .donationsCTAModalAppearanceCount: result.append(.donationsCTAModalAppearanceCount); fallthrough
                case .customFirstInstallDateTime: result.append(.customFirstInstallDateTime); fallthrough
                case .donationsUrlOpenCount: result.append(.donationsUrlOpenCount); fallthrough
                case .donationsUrlCopyCount: result.append(.donationsUrlCopyCount); fallthrough
                case .resetAppReviewPrompt: result.append(.resetAppReviewPrompt); fallthrough
                case .simulateAppReviewLimit: result.append(.simulateAppReviewLimit); fallthrough
                case .versionDeprecationWarning: result.append(.versionDeprecationWarning); fallthrough
                case .versionDeprecationMinimum:
                    result.append(.versionDeprecationMinimum)
            }
            
            return result
        }
    }
    
    // MARK: - Content
    
    public struct State: Equatable, ObservableKeyProvider {
        let donationsCTAModalAppearanceCount: Int
        let donationsCTAModalLastAppearanceTimestamp: TimeInterval?
        let customFirstInstallDateTime: TimeInterval?
        let donationsUrlOpenCount: Int
        let donationsUrlCopyCount: Int
        
        let simulateAppReviewLimit: Bool
        
        let versionDeprecationWarning: Bool
        let versionDeprecationMinimum: Int
        
        @MainActor public func sections(viewModel: DeveloperSettingsModalsAndBannersViewModel, previousState: State) -> [SectionModel] {
            DeveloperSettingsModalsAndBannersViewModel.sections(
                state: self,
                previousState: previousState,
                viewModel: viewModel
            )
        }
        
        public let observedKeys: Set<ObservableKey> = [
            .userDefault(.donationsCTAModalAppearanceCount),
            .userDefault(.donationsCTAModalLastAppearanceTimestamp),
            .feature(.customFirstInstallDateTime),
            .userDefault(.donationsUrlOpenCount),
            .userDefault(.donationsUrlCopyCount),
            .feature(.simulateAppReviewLimit),
            .feature(.versionDeprecationWarning),
            .feature(.versionDeprecationMinimum)
        ]
        
        static func initialState(using dependencies: Dependencies) -> State {
            return State(
                donationsCTAModalAppearanceCount: dependencies[defaults: .standard, key: .donationsCTAModalAppearanceCount],
                donationsCTAModalLastAppearanceTimestamp: dependencies[defaults: .standard, key: .donationsCTAModalLastAppearanceTimestamp],
                customFirstInstallDateTime: dependencies[feature: .customFirstInstallDateTime],
                donationsUrlOpenCount: dependencies[defaults: .standard, key: .donationsUrlOpenCount],
                donationsUrlCopyCount: dependencies[defaults: .standard, key: .donationsUrlCopyCount],
                simulateAppReviewLimit: dependencies[feature: .simulateAppReviewLimit],
                versionDeprecationWarning: dependencies[feature: .versionDeprecationWarning],
                versionDeprecationMinimum: dependencies[feature: .versionDeprecationMinimum]
            )
        }
    }
    
    let title: String = "Developer Modal and Banner Settings"
    
    @Sendable private static func queryState(
        previousState: State,
        events: [ObservedEvent],
        isInitialQuery: Bool,
        using dependencies: Dependencies
    ) async -> State {
        return State(
            donationsCTAModalAppearanceCount: dependencies[defaults: .standard, key: .donationsCTAModalAppearanceCount],
            donationsCTAModalLastAppearanceTimestamp: dependencies[defaults: .standard, key: .donationsCTAModalLastAppearanceTimestamp],
            customFirstInstallDateTime: dependencies[feature: .customFirstInstallDateTime],
            donationsUrlOpenCount: dependencies[defaults: .standard, key: .donationsUrlOpenCount],
            donationsUrlCopyCount: dependencies[defaults: .standard, key: .donationsUrlCopyCount],
            simulateAppReviewLimit: dependencies[feature: .simulateAppReviewLimit],
            versionDeprecationWarning: dependencies[feature: .versionDeprecationWarning],
            versionDeprecationMinimum: dependencies[feature: .versionDeprecationMinimum]
        )
    }
    
    private static func sections(
        state: State,
        previousState: State,
        viewModel: DeveloperSettingsModalsAndBannersViewModel
    ) -> [SectionModel] {
        let customFirstInstallDateTime: String = {
            guard let customFirstInstallDateTimestamp: TimeInterval = viewModel.dependencies[feature: .customFirstInstallDateTime] else {
                return "<disabled>None</disabled>"
            }
            
            return "<span>\(Date(timeIntervalSince1970: customFirstInstallDateTimestamp).formattedForBanner)</span>"
        }()
        let donationsCTAModalLastAppearanceTime: String = {
            let donationsCTAModalLastAppearanceTimestamp: TimeInterval = viewModel.dependencies[defaults: .standard, key: .donationsCTAModalLastAppearanceTimestamp]
            
            guard donationsCTAModalLastAppearanceTimestamp > 0 else {
                return "<disabled>None</disabled>"
            }
            
            return "<span>\(Date(timeIntervalSince1970: donationsCTAModalLastAppearanceTimestamp).formattedForBanner)</span>"
        }()
        
        let donations: SectionModel = SectionModel(
            model: .donations,
            elements: [
                SessionCell.Info(
                    id: .showDonationsCTAModal,
                    title: "Show Donations CTA Modal",
                    subtitle: """
                    Forcibly show the docations CTA modal.
                    
                    <b>Note:</b> This will result in the various counters being incremented.
                    """,
                    trailingAccessory: .icon(.squareArrowOutUpRight),
                    onTap: { [dependencies = viewModel.dependencies] in
                        guard let frontMostViewController: UIViewController = dependencies[singleton: .appContext].frontMostViewController else {
                            return
                        }
                        
                        dependencies[singleton: .donationsManager].presentDonationsCTAModal(in: frontMostViewController)
                    }
                ),
                SessionCell.Info(
                    id: .donationsCTAModalAppearanceCount,
                    title: "Donations CTA Modal Appearance Count",
                    subtitle: """
                    The number of times the user has copied the donations URL.
                    
                    <b>Last Appeared Timestamp:</b> \(donationsCTAModalLastAppearanceTime)
                    
                    <b>Note:</b> An empty value will reset the count and "Last Appeared Timestamp" to 0.
                    """,
                    trailingAccessory: .custom(info: NumberInputView.Info(
                        value: state.donationsCTAModalAppearanceCount,
                        minValue: 0,
                        onDone: { [dependencies = viewModel.dependencies] newValue in
                            dependencies[defaults: .standard, key: .donationsCTAModalAppearanceCount] = (newValue ?? 0)
                            
                            if newValue == nil {
                                viewModel.dependencies[defaults: .standard, key: .donationsCTAModalLastAppearanceTimestamp] = 0
                            }
                        }
                    )),
                    onTapView: { view in
                        view?.subviews
                            .flatMap { $0.subviews }
                            .first(where: { $0 is UITextField })?
                            .becomeFirstResponder()
                    }
                ),
                SessionCell.Info(
                    id: .customFirstInstallDateTime,
                    title: "Custom First Install Date/Time",
                    subtitle: """
                    Specify a custom date/time that the app was first installed.
                    
                    <b>Current Value:</b> \(customFirstInstallDateTime)
                    """,
                    trailingAccessory: .icon(.squarePen),
                    onTap: { [weak viewModel] in
                        viewModel?.showCustomDateTimeModal()
                    }
                ),
                SessionCell.Info(
                    id: .donationsUrlOpenCount,
                    title: "Donations URL Open Count",
                    subtitle: """
                    The number of times the user has opened the donations URL.
                    
                    <b>Note:</b> An empty value will be considered 0.
                    """,
                    trailingAccessory: .custom(info: NumberInputView.Info(
                        value: state.donationsUrlOpenCount,
                        minValue: 0,
                        onDone: { [dependencies = viewModel.dependencies] newValue in
                            dependencies[defaults: .standard, key: .donationsUrlOpenCount] = (newValue ?? 0)
                        }
                    )),
                    onTapView: { view in
                        view?.subviews
                            .flatMap { $0.subviews }
                            .first(where: { $0 is UITextField })?
                            .becomeFirstResponder()
                    }
                ),
                SessionCell.Info(
                    id: .donationsUrlCopyCount,
                    title: "Donations URL Copy Count",
                    subtitle: """
                    The number of times the user has copied the donations URL.
                    
                    <b>Note:</b> An empty value will be considered 0.
                    """,
                    trailingAccessory: .custom(info: NumberInputView.Info(
                        value: state.donationsUrlCopyCount,
                        minValue: 0,
                        onDone: { [dependencies = viewModel.dependencies] newValue in
                            dependencies[defaults: .standard, key: .donationsUrlCopyCount] = (newValue ?? 0)
                        }
                    )),
                    onTapView: { view in
                        view?.subviews
                            .flatMap { $0.subviews }
                            .first(where: { $0 is UITextField })?
                            .becomeFirstResponder()
                    }
                )
            ]
        )
        let appReview: SectionModel = SectionModel(
            model: .appReview,
            elements: [
                SessionCell.Info(
                    id: .resetAppReviewPrompt,
                    title: "Reset App Review Prompt",
                    subtitle: """
                    Clears user default settings for the app review prompt, enabling quicker testing of various display conditions.
                    """,
                    trailingAccessory: .highlightingBackgroundLabel(title: "Reset"),
                    onTap: { [weak viewModel] in
                        viewModel?.resetAppReviewPrompt()
                    }
                ),
                SessionCell.Info(
                    id: .simulateAppReviewLimit,
                    title: "Simulate App Review Limit",
                    subtitle: """
                    Controls whether the in-app rating prompt is displayed. This can will simulate a rate limit, preventing the prompt from appearing.
                    """,
                    trailingAccessory: .toggle(
                        state.simulateAppReviewLimit,
                        oldValue: previousState.simulateAppReviewLimit
                    ),
                    onTap: { [dependencies = viewModel.dependencies] in
                        dependencies.set(
                            feature: .simulateAppReviewLimit,
                            to: !state.simulateAppReviewLimit
                        )
                    }
                )
            ]
        )
        let versionDeprecation: SectionModel = SectionModel(
            model: .versionDeprecation,
            elements: [
                SessionCell.Info(
                    id: .versionDeprecationWarning,
                    title: "Version Deprecation Banner",
                    subtitle: """
                    Enable the banner that warns users when their operating system (iOS 15.x or earlier) is nearing the end of support or cannot access the latest features.
                    """,
                    trailingAccessory: .toggle(
                        state.versionDeprecationWarning,
                        oldValue: previousState.versionDeprecationWarning
                    ),
                    onTap: { [dependencies = viewModel.dependencies] in
                        dependencies.set(
                            feature: .versionDeprecationWarning,
                            to: !state.versionDeprecationWarning
                        )
                    }
                ),
                SessionCell.Info(
                    id: .versionDeprecationMinimum,
                    title: "Version Deprecation Minimum Version",
                    subtitle: """
                    The minimum version allowed before showing version deprecation warning.
                    """,
                    trailingAccessory: .dropDown { "iOS \(state.versionDeprecationMinimum)" },
                    onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                        viewModel?.transitionToScreen(
                            SessionTableViewController(
                                viewModel: SessionListViewModel<WarningVersion>(
                                    title: "Minimum iOS Version",
                                    options: [
                                        WarningVersion(version: 16),
                                        WarningVersion(version: 17),
                                        WarningVersion(version: 18)
                                    ],
                                    behaviour: .autoDismiss(
                                        initialSelection: WarningVersion(version: state.versionDeprecationMinimum),
                                        onOptionSelected: { selected in
                                            dependencies.set(feature: .versionDeprecationMinimum, to: selected.version)
                                        }
                                    ),
                                    using: dependencies
                                )
                            )
                        )
                    }
                )
            ]
        )
        
        return [donations, appReview, versionDeprecation]
    }
    
    // MARK: - Functions
    
    public static func disableDeveloperMode(using dependencies: Dependencies) {
        TableItem.allCases.forEach { item in
            switch item {
                case .showDonationsCTAModal, .resetAppReviewPrompt:
                    break   /// These are actions rather than values stored as "features" so no need to do anything
                    
                case .donationsUrlOpenCount, .donationsUrlCopyCount, .donationsCTAModalAppearanceCount:
                    break   /// These are _actual_ values so we shouldn't reset them - the changes just apply permanently
                    
                case .customFirstInstallDateTime:
                    guard dependencies.hasSet(feature: .customFirstInstallDateTime) else { return }
                    
                    dependencies.set(feature: .customFirstInstallDateTime, to: nil)
                    
                case .simulateAppReviewLimit:
                    guard dependencies.hasSet(feature: .simulateAppReviewLimit) else { return }
                    
                    dependencies.set(feature: .simulateAppReviewLimit, to: nil)
                    
                case .versionDeprecationWarning:
                    guard dependencies.hasSet(feature: .versionDeprecationWarning) else { return }
                    
                    dependencies.set(feature: .versionDeprecationWarning, to: nil)
                    
                case .versionDeprecationMinimum:
                    guard dependencies.hasSet(feature: .versionDeprecationMinimum) else { return }
                    
                    dependencies.set(feature: .versionDeprecationMinimum, to: nil)
            }
        }
    }
    
    private func showCustomDateTimeModal() {
        let formatter: DateFormatter = DateFormatter()
        formatter.dateFormat = "HH:mm dd/MM/yyyy"
        
        self.updatedCustomDateTime = nil
        self.transitionToScreen(
            ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: "Custom First Install Date/Time",
                    body: .input(
                        explanation: ThemedAttributedString(
                            string: "The custom date/time the app was first installed."
                        ),
                        info: ConfirmationModal.Info.Body.InputInfo(
                            placeholder: "Enter Date/Time (HH:mm dd/MM/yyyy)",
                            initialValue: (dependencies[feature: .customFirstInstallDateTime]
                                .map { formatter.string(from: Date(timeIntervalSince1970: $0)) } ?? "")
                        ),
                        onChange: { [weak self] value in
                            self?.updatedCustomDateTime = value.lowercased()
                        }
                    ),
                    confirmTitle: "save".localized(),
                    confirmEnabled: .afterChange { [weak self] _ in
                        guard
                            let value: String = self?.updatedCustomDateTime,
                            formatter.date(from: value) != nil
                        else { return false }
                        
                        return true
                    },
                    cancelTitle: (dependencies.hasSet(feature: .customFirstInstallDateTime) ?
                        "remove".localized() :
                        "cancel".localized()
                    ),
                    cancelStyle: (dependencies.hasSet(feature: .customFirstInstallDateTime) ? .danger : .alert_text),
                    hasCloseButton: dependencies.hasSet(feature: .customFirstInstallDateTime),
                    dismissOnConfirm: false,
                    onConfirm: { [weak self, dependencies] modal in
                        guard
                            let value: String = self?.updatedCustomDateTime,
                            let date: Date = formatter.date(from: value)
                        else {
                            modal.updateContent(
                                withError: "Value must be in the format 'HH:mm dd/MM/yyyy'."
                            )
                            return
                        }
                        
                        modal.dismiss(animated: true)
                        
                        dependencies.set(feature: .customFirstInstallDateTime, to: date.timeIntervalSince1970)
                    },
                    onCancel: { [dependencies] modal in
                        modal.dismiss(animated: true)
                        
                        guard !dependencies.hasSet(feature: .customFirstInstallDateTime) else { return }
                        
                        dependencies.set(feature: .customFirstInstallDateTime, to: nil)
                    }
                )
            ),
            transitionType: .present
        )
    }
    
    private func resetAppReviewPrompt() {
        dependencies[defaults: .standard, key: .didShowAppReviewPrompt] = false
        dependencies[defaults: .standard, key: .hasVisitedPathScreen] = false
        dependencies[defaults: .standard, key: .hasPressedDonateButton] = false
        dependencies[defaults: .standard, key: .hasChangedTheme] = false
        dependencies[defaults: .standard, key: .rateAppRetryDate] = nil
        dependencies[defaults: .standard, key: .rateAppRetryAttemptCount] = 0
        
        showToast(
            text: "Cleared",
            backgroundColor: .backgroundSecondary
        )
    }
}
