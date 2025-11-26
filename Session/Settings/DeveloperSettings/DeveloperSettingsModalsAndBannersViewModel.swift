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
        case donationsCTAModalLastAppearanceTimestamp
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
                case .donationsCTAModalLastAppearanceTimestamp: return "donationsCTAModalLastAppearanceTimestamp"
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
                case .donationsCTAModalLastAppearanceTimestamp: result.append(.donationsCTAModalLastAppearanceTimestamp); fallthrough
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
                    The number of times the donations CTA modal has appeared.
                    
                    <b>Current Value:</b> \(devValue: state.donationsCTAModalAppearanceCount)
                    
                    <b>Note:</b> An value of 0 will reset the "Last Appeared Timestamp".
                    """,
                    trailingAccessory: .icon(.squarePen),
                    onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                        DeveloperSettingsViewModel.showModalForMockableNumber(
                            title: "Donations CTA Modal Appearance Count",
                            explanation: "The number of times the donations CTA modal has appeared.",
                            defaults: .standard,
                            key: .donationsCTAModalAppearanceCount,
                            minValue: 0,
                            navigatableStateHolder: viewModel,
                            onValueChanged: { newValue in
                                guard (newValue ?? 0) == 0 else { return }
                                
                                dependencies[defaults: .standard].removeObject(
                                    forKey: UserDefaults.DoubleKey.donationsCTAModalLastAppearanceTimestamp.rawValue
                                )
                            },
                            using: dependencies
                        )
                    }
                ),
                SessionCell.Info(
                    id: .donationsCTAModalLastAppearanceTimestamp,
                    title: "Donations CTA Last Appeared Timestamp",
                    subtitle: """
                    The last time the donations CTA modal has appeared.
                    
                    <b>Current Value:</b> \(devValue: state.donationsCTAModalLastAppearanceTimestamp)
                    """,
                    trailingAccessory: .icon(.squarePen),
                    onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                        DeveloperSettingsViewModel.showModalForMockableDate(
                            title: "Donations CTA Modal Last Appearance Date/Time",
                            explanation: "The date/time the donations CTA modal last appeared.",
                            defaults: .standard,
                            key: .donationsCTAModalLastAppearanceTimestamp,
                            navigatableStateHolder: viewModel,
                            using: dependencies
                        )
                    }
                ),
                SessionCell.Info(
                    id: .customFirstInstallDateTime,
                    title: "Custom First Install Date/Time",
                    subtitle: """
                    Specify a custom date/time that the app was first installed.
                    
                    <b>Current Value:</b> \(devValue: viewModel.dependencies[feature: .customFirstInstallDateTime])
                    """,
                    trailingAccessory: .icon(.squarePen),
                    onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                        DeveloperSettingsViewModel.showModalForMockableDate(
                            title: "Custom First Install Date/Time",
                            explanation: "The custom date/time the app was first installed.",
                            feature: .customFirstInstallDateTime,
                            navigatableStateHolder: viewModel,
                            using: dependencies
                        )
                    }
                ),
                SessionCell.Info(
                    id: .donationsUrlOpenCount,
                    title: "Donations URL Open Count",
                    subtitle: """
                    The number of times the user has opened the donations URL.
                    
                    <b>Current Value:</b> \(devValue: state.donationsUrlOpenCount)
                    """,
                    trailingAccessory: .icon(.squarePen),
                    onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                        DeveloperSettingsViewModel.showModalForMockableNumber(
                            title: "Donations URL Open Count",
                            explanation: "The number of times the user has opened the donations URL.",
                            defaults: .standard,
                            key: .donationsUrlOpenCount,
                            minValue: 0,
                            navigatableStateHolder: viewModel,
                            using: dependencies
                        )
                    }
                ),
                SessionCell.Info(
                    id: .donationsUrlCopyCount,
                    title: "Donations URL Copy Count",
                    subtitle: """
                    The number of times the user has copied the donations URL.
                    
                    <b>Current Value:</b> \(devValue: state.donationsUrlCopyCount)
                    """,
                    trailingAccessory: .icon(.squarePen),
                    onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                        DeveloperSettingsViewModel.showModalForMockableNumber(
                            title: "Donations URL Copy Count",
                            explanation: "The number of times the user has copied the donations URL.",
                            defaults: .standard,
                            key: .donationsUrlCopyCount,
                            minValue: 0,
                            navigatableStateHolder: viewModel,
                            using: dependencies
                        )
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
                    
                case .donationsUrlOpenCount, .donationsUrlCopyCount, .donationsCTAModalAppearanceCount,
                    .donationsCTAModalLastAppearanceTimestamp:
                    break   /// These are _actual_ values so we shouldn't reset them - the changes just apply permanently
                    
                case .customFirstInstallDateTime:
                    guard dependencies.hasSet(feature: .customFirstInstallDateTime) else { return }
                    
                    dependencies.reset(feature: .customFirstInstallDateTime)
                    
                case .simulateAppReviewLimit:
                    guard dependencies.hasSet(feature: .simulateAppReviewLimit) else { return }
                    
                    dependencies.reset(feature: .simulateAppReviewLimit)
                    
                case .versionDeprecationWarning:
                    guard dependencies.hasSet(feature: .versionDeprecationWarning) else { return }
                    
                    dependencies.reset(feature: .versionDeprecationWarning)
                    
                case .versionDeprecationMinimum:
                    guard dependencies.hasSet(feature: .versionDeprecationMinimum) else { return }
                    
                    dependencies.reset(feature: .versionDeprecationMinimum)
            }
        }
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
