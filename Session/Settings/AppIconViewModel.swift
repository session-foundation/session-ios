// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

// MARK: - AppIcon

enum AppIcon: String, CaseIterable {
    case session = "AppIcon"
    
    case weather = "AppIcon-Weather"
    case stocks = "AppIcon-Stocks"
    case news = "AppIcon-News"
    case notes = "AppIcon-Notes"
    case meetings = "AppIcon-Meeting"
    case calculator = "AppIcon-Calculator"
    
    /// Annoyingly the alternate icons don't seem to be renderable directly so we need to include
    /// additional copies in order to render in the UI
    var previewImageName: String { "\(rawValue)-Preview" }
    
    // stringlint:ignore_contents
    init(name: String?) {
        switch name {
            case "AppIcon-Weather": self = .weather
            case "AppIcon-Stocks": self = .stocks
            case "AppIcon-News": self = .news
            case "AppIcon-Notes": self = .notes
            case "AppIcon-Meeting": self = .meetings
            case "AppIcon-Calculator": self = .calculator
            default: self = .session
        }
    }
    
    init?(rawValue: String) {
        self.init(name: rawValue)
    }
}

// MARK: - AppIconViewModel

class AppIconViewModel: SessionTableViewModel, NavigatableStateHolder, ObservableTableSource {
    public let dependencies: Dependencies
    public let navigatableState: NavigatableState = NavigatableState()
    public let state: TableDataState<Section, TableItem> = TableDataState()
    public let observableState: ObservableTableSourceState<Section, TableItem> = ObservableTableSourceState()
    private let selectedOptionsSubject: CurrentValueSubject<String?, Never>
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        
        /// Retrieve the current icon name
        var currentIconName: String?
        
        switch Thread.isMainThread {
            case true: currentIconName = UIApplication.shared.alternateIconName
            case false:
                DispatchQueue.main.sync {
                    currentIconName = UIApplication.shared.alternateIconName
                }
        }
        
        selectedOptionsSubject = CurrentValueSubject(currentIconName)
    }
    
    // MARK: - Section
    
    public enum Section: SessionTableSection {
        case appIcon
        case icon
        
        var title: String? {
            switch self {
                case .appIcon: return "appIcon".localized()
                case .icon: return "appIconSelectionTitle".localized()
            }
        }
        
        var style: SessionTableSectionStyle {
            switch self {
                case .appIcon: return .titleRoundedContent
                case .icon: return .padding
            }
        }
        
        var footer: String? {
            switch self {
                case .icon:
                    return "appIconDescription"
                        .put(key: "app_name", value: Constants.app_name)
                        .localized()
                default: return nil
            }
        }
    }
    
    public enum TableItem: Equatable, Hashable, Differentiable {
        case appIconUseAlternate
        case iconGrid
    }
    
    // MARK: - Content
    
    private struct State: Equatable {
        let alternateAppIconName: String?
    }
    
    let title: String = "sessionAppearance".localized()
    
    lazy var observation: TargetObservation = ObservationBuilderOld
        .subject(selectedOptionsSubject)
        .mapWithPrevious { [weak self, dependencies] previous, current -> [SectionModel] in
            return [
                SectionModel(
                    model: .appIcon,
                    elements: [
                        SessionCell.Info(
                            id: .appIconUseAlternate,
                            title: SessionCell.TextInfo(
                                "appIconEnableIcon".localized(),
                                font: .titleRegular
                            ),
                            trailingAccessory: .toggle(
                                (current != nil),
                                oldValue: (previous != nil)
                            ),
                            onTap: { [weak self] in
                                switch current {
                                    case .some: self?.updateAppIcon(nil)
                                    case .none: self?.updateAppIcon(.weather)
                                }
                            }
                        )
                    ]
                ),
                SectionModel(
                    model: .icon,
                    elements: [
                        SessionCell.Info(
                            id: .iconGrid,
                            leadingAccessory: .custom(
                                info: AppIconGridView.Info(
                                    selectedIcon: AppIcon(name: current),
                                    onChange: { icon in self?.updateAppIcon(icon) }
                                )
                            )
                        )
                    ]
                )
            ]
        }
    
    private func updateAppIcon(_ icon: AppIcon?) {
        // Ignore if there wasn't a change
        guard selectedOptionsSubject.value != icon?.rawValue else { return }
        
        UIApplication.shared.setAlternateIconName(icon?.rawValue) { error in
            guard let error: Error = error else { return }
            
            Log.error("Failed to set alternate icon: \(error)")
        }
        
        selectedOptionsSubject.send(icon?.rawValue)
    }
}
