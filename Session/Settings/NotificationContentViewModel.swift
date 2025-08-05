// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

class NotificationContentViewModel: SessionTableViewModel, NavigatableStateHolder, ObservableTableSource {
    typealias TableItem = Preferences.NotificationPreviewType
    
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
        case content
    }
    
    // MARK: - Content
    
    public struct State: ObservableKeyProvider {
        let previewType: Preferences.NotificationPreviewType
        
        @MainActor public func sections(viewModel: NotificationContentViewModel) -> [SectionModel] {
            NotificationContentViewModel.sections(state: self, viewModel: viewModel)
        }
        
        /// No observations as we dismiss the screen when selecting an option
        public let observedKeys: Set<ObservableKey> = []
        
        static func initialState() -> State {
            return State(
                previewType: .defaultPreviewType
            )
        }
    }
    
    let title: String = "notificationsContent".localized()
    
    @MainActor private func bindState() {
        observationTask = ObservationBuilder
            .initialValue(self.internalState)
            .debounce(for: .never)
            .using(dependencies: dependencies)
            .query(NotificationContentViewModel.queryState)
            .assign { [weak self] updatedState in
                guard let self = self else { return }
                
                // FIXME: To slightly reduce the size of the changes this new observation mechanism is currently wired into the old SessionTableViewController observation mechanism, we should refactor it so everything uses the new mechanism
                self.internalState = updatedState
                self.pendingTableDataSubject.send(updatedState.sections(viewModel: self))
            }
    }
    
    @Sendable private static func queryState(
        previousState: State,
        events: [ObservedEvent],
        isInitialQuery: Bool,
        using dependencies: Dependencies
    ) async -> State {
        var previewType: Preferences.NotificationPreviewType = previousState.previewType
        
        if isInitialQuery {
            dependencies.mutate(cache: .libSession) { libSession in
                previewType = (libSession.get(.preferencesNotificationPreviewType) ?? previewType)
            }
        }
        
        return State(
            previewType: previewType
        )
    }
    
    private static func sections(state: State, viewModel: NotificationContentViewModel) -> [SectionModel] {
        return [
            SectionModel(
                model: .content,
                elements: Preferences.NotificationPreviewType.allCases
                    .map { previewType in
                        SessionCell.Info(
                            id: previewType,
                            title: previewType.name,
                            trailingAccessory: .radio(
                                isSelected: (state.previewType == previewType)
                            ),
                            onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                                dependencies.setAsync(.preferencesNotificationPreviewType, previewType) { [weak viewModel] in
                                    viewModel?.dismissScreen()
                                }
                            }
                        )
                    }
            )
        ]
    }
}
