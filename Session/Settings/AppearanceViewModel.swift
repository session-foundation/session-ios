// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

class AppearanceViewModel: SessionTableViewModel, NavigatableStateHolder, ObservableTableSource {
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
        self.internalState = State.initialState()
        
        bindState()
    }
    
    // MARK: - Section
    
    public enum Section: SessionTableSection {
        case themes
        case primaryColor
        case primaryColorSelection
        case autoDarkMode
        case appIcon
        
        var title: String? {
            switch self {
                case .themes: return "appearanceThemes".localized()
                case .primaryColor: return "appearancePrimaryColor".localized()
                case .primaryColorSelection: return nil
                case .autoDarkMode: return "darkMode".localized()
                case .appIcon: return "appIcon".localized()
            }
        }
        
        var style: SessionTableSectionStyle {
            switch self {
                case .primaryColorSelection: return .none
                default: return .titleRoundedContent
            }
        }
    }
    
    public enum TableItem: Equatable, Hashable, Differentiable {
        case theme(Int)
        case primaryColorPreview
        case primaryColorSelectionView
        case darkModeMatchSystemSettings
    }
    
    // MARK: - Content
    
    public struct State: ObservableKeyProvider {
        let theme: Theme
        let primaryColor: Theme.PrimaryColor
        let autoDarkModeEnabled: Bool
        
        @MainActor public func sections(viewModel: AppearanceViewModel, previousState: State) -> [SectionModel] {
            AppearanceViewModel.sections(
                state: self,
                previousState: previousState,
                viewModel: viewModel
            )
        }
        
        public let observedKeys: Set<ObservableKey> = [
            .setting(.theme),
            .setting(.themePrimaryColor),
            .setting(.themeMatchSystemDayNightCycle)
        ]
        
        static func initialState() -> State {
            return State(
                theme: .defaultTheme,
                primaryColor: .defaultPrimaryColor,
                autoDarkModeEnabled: false
            )
        }
    }
    
    let title: String = "sessionAppearance".localized()
    
    @MainActor private func bindState() {
        observationTask = ObservationBuilder
            .initialValue(self.internalState)
            .debounce(for: .milliseconds(10))   /// Changes trigger multiple events at once so debounce them
            .using(dependencies: dependencies)
            .query(AppearanceViewModel.queryState)
            .assign { [weak self] updatedState in
                guard let self = self else { return }
                
                // FIXME: To slightly reduce the size of the changes this new observation mechanism is currently wired into the old SessionTableViewController observation mechanism, we should refactor it so everything uses the new mechanism
                let oldState: State = self.internalState
                self.internalState = updatedState
                self.pendingTableDataSubject.send(updatedState.sections(viewModel: self, previousState: oldState))
            }
    }
    
    @Sendable private static func queryState(
        previousState: State,
        events: [ObservedEvent],
        isInitialQuery: Bool,
        using dependencies: Dependencies
    ) async -> State {
        var theme: Theme = previousState.theme
        var primaryColor: Theme.PrimaryColor = previousState.primaryColor
        var autoDarkModeEnabled: Bool = previousState.autoDarkModeEnabled
        
        if isInitialQuery {
            dependencies.mutate(cache: .libSession) { libSession in
                theme = (libSession.get(.theme) ?? theme)
                primaryColor = (libSession.get(.themePrimaryColor) ?? primaryColor)
                autoDarkModeEnabled = libSession.get(.themeMatchSystemDayNightCycle)
            }
        }
        
        /// Process any event changes
        events.forEach { event in
            switch (event.key, event.value) {
                case (.setting(.theme), let updatedValue as Theme): theme = updatedValue
                
                case (.setting(.themePrimaryColor), let updatedValue as Theme.PrimaryColor):
                    primaryColor = updatedValue
                    
                case (.setting(.themeMatchSystemDayNightCycle), let updatedValue as Bool):
                    autoDarkModeEnabled = updatedValue
                
                default: break
            }
        }
        
        /// Generate the new state
        return State(
            theme: theme,
            primaryColor: primaryColor,
            autoDarkModeEnabled: autoDarkModeEnabled
        )
    }
    
    private static func sections(
        state: State,
        previousState: State,
        viewModel: AppearanceViewModel
    ) -> [SectionModel] {
            return [
                SectionModel(
                    model: .themes,
                    elements: Theme.allCases.map { theme in
                        SessionCell.Info(
                            id: .theme(theme.rawValue),
                            leadingAccessory: .custom(
                                info: ThemePreviewView.Info(theme: theme)
                            ),
                            title: theme.title,
                            trailingAccessory: .radio(
                                isSelected: (state.theme == theme)
                            ),
                            onTap: { [dependencies = viewModel.dependencies] in
                                ThemeManager.updateThemeState(theme: theme)
                                // Update trigger only if it's not set to true
                                if !dependencies[defaults: .standard, key: .hasChangedTheme] {
                                    dependencies[defaults: .standard, key: .hasChangedTheme] = true
                                }
                            }
                        )
                    }
                ),
                SectionModel(
                    model: .primaryColor,
                    elements: [
                        SessionCell.Info(
                            id: .primaryColorPreview,
                            leadingAccessory: .custom(
                                info: ThemeMessagePreviewView.Info()
                            )
                        )
                    ]
                ),
                SectionModel(
                    model: .primaryColorSelection,
                    elements: [
                        SessionCell.Info(
                            id: .primaryColorSelectionView,
                            leadingAccessory: .custom(
                                info: PrimaryColorSelectionView.Info(
                                    primaryColor: state.primaryColor,
                                    onChange: { color in
                                        ThemeManager.updateThemeState(primaryColor: color)
                                    }
                                )
                            ),
                            styling: SessionCell.StyleInfo(
                                customPadding: .none,
                                backgroundStyle: .noBackground
                            )
                        )
                    ]
                ),
                SectionModel(
                    model: .autoDarkMode,
                    elements: [
                        SessionCell.Info(
                            id: .darkModeMatchSystemSettings,
                            title: "appearanceAutoDarkMode".localized(),
                            subtitle: "followSystemSettings".localized(),
                            trailingAccessory: .toggle(
                                state.autoDarkModeEnabled,
                                oldValue: previousState.autoDarkModeEnabled
                            ),
                            onTap: {
                                ThemeManager.updateThemeState(
                                    theme: state.theme,                 /// Keep the current value
                                    primaryColor: state.primaryColor,   /// Keep the current value
                                    matchSystemNightModeSetting: !state.autoDarkModeEnabled
                                )
                            }
                        )
                    ]
                ),
                SectionModel(
                    model: .appIcon,
                    elements: [
                        SessionCell.Info(
                            id: .darkModeMatchSystemSettings,
                            title: SessionCell.TextInfo(
                                "appIconSelect".localized(),
                                font: .titleRegular
                            ),
                            trailingAccessory: .icon(
                                .chevronRight,
                                pinEdges: [.right]
                            ),
                            onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                                viewModel?.transitionToScreen(
                                    SessionTableViewController(
                                        viewModel: AppIconViewModel(using: dependencies)
                                    )
                                )
                            }
                        )
                    ]
                )
            ]
        }
}
