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
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
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
                case .autoDarkMode: return "appearanceAutoDarkMode".localized()
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
        case theme(String)
        case primaryColorPreview
        case primaryColorSelectionView
        case darkModeMatchSystemSettings
    }
    
    // MARK: - Content
    
    private struct State: Equatable {
        let theme: Theme
        let primaryColor: Theme.PrimaryColor
        let authDarkModeEnabled: Bool
    }
    
    let searchable: Bool = false
    let title: String = "sessionAppearance".localized()
    
    lazy var observation: TargetObservation = ObservationBuilder
        .databaseObservation(self) { db -> State in
            State(
                theme: db[.theme].defaulting(to: .classicDark),
                primaryColor: db[.themePrimaryColor].defaulting(to: .green),
                authDarkModeEnabled: db[.themeMatchSystemDayNightCycle]
            )
        }
        .map { [weak self, dependencies] state -> [SectionModel] in
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
                            onTap: {
                                ThemeManager.updateThemeState(theme: theme)
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
                            title: SessionCell.TextInfo(
                                "followSystemSettings".localized(),
                                font: .titleRegular
                            ),
                            trailingAccessory: .toggle(
                                state.authDarkModeEnabled,
                                oldValue: ThemeManager.matchSystemNightModeSetting
                            ),
                            onTap: {
                                ThemeManager.updateThemeState(
                                    matchSystemNightModeSetting: !state.authDarkModeEnabled
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
                            trailingAccessory: .icon(.chevronRight),
                            onTap: { [weak self, dependencies] in
                                self?.transitionToScreen(
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
