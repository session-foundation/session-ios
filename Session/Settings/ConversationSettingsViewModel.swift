// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

class ConversationSettingsViewModel: SessionTableViewModel, NavigatableStateHolder, ObservableTableSource {
    typealias TableItem = Section
    
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
        case messageTrimming
        case audioMessages
        case blockedContacts
        
        var title: String? {
            switch self {
                case .messageTrimming: return "conversationsMessageTrimming".localized()
                case .audioMessages: return "conversationsAudioMessages".localized()
                case .blockedContacts: return "conversationsBlockedContacts".localized()
            }
        }
        
        var style: SessionTableSectionStyle { .titleRoundedContent }
    }
    
    // MARK: - Content
    
    public struct State: ObservableKeyProvider {
        let trimOpenGroupMessagesOlderThanSixMonths: Bool
        let shouldAutoPlayConsecutiveAudioMessages: Bool
        
        @MainActor public func sections(viewModel: ConversationSettingsViewModel, previousState: State) -> [SectionModel] {
            ConversationSettingsViewModel.sections(
                state: self,
                previousState: previousState,
                viewModel: viewModel
            )
        }
        
        public let observedKeys: Set<ObservableKey> = [
            .setting(.trimOpenGroupMessagesOlderThanSixMonths),
            .setting(.shouldAutoPlayConsecutiveAudioMessages)
        ]
        
        static func initialState() -> State {
            return State(
                trimOpenGroupMessagesOlderThanSixMonths: false,
                shouldAutoPlayConsecutiveAudioMessages: false
            )
        }
    }
    
    let title: String = "sessionConversations".localized()
    
    @MainActor private func bindState() {
        observationTask = ObservationBuilder
            .initialValue(self.internalState)
            .debounce(for: .never)
            .using(dependencies: dependencies)
            .query(ConversationSettingsViewModel.queryState)
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
        var trimOpenGroupMessagesOlderThanSixMonths: Bool = previousState.trimOpenGroupMessagesOlderThanSixMonths
        var shouldAutoPlayConsecutiveAudioMessages: Bool = previousState.shouldAutoPlayConsecutiveAudioMessages
        
        if isInitialQuery {
            dependencies.mutate(cache: .libSession) { libSession in
                trimOpenGroupMessagesOlderThanSixMonths = libSession.get(.trimOpenGroupMessagesOlderThanSixMonths)
                shouldAutoPlayConsecutiveAudioMessages = libSession.get(.shouldAutoPlayConsecutiveAudioMessages)
            }
        }
        
        /// Process any event changes
        events.forEach { event in
            guard let updatedValue: Bool = event.value as? Bool else { return }
            
            switch event.key {
                case .setting(.trimOpenGroupMessagesOlderThanSixMonths):
                    trimOpenGroupMessagesOlderThanSixMonths = updatedValue
                    
                case .setting(.shouldAutoPlayConsecutiveAudioMessages):
                    shouldAutoPlayConsecutiveAudioMessages = updatedValue
                
                default: break
            }
        }
        
        /// Generate the new state
        return State(
            trimOpenGroupMessagesOlderThanSixMonths: trimOpenGroupMessagesOlderThanSixMonths,
            shouldAutoPlayConsecutiveAudioMessages: shouldAutoPlayConsecutiveAudioMessages
        )
    }
    
    private static func sections(
        state: State,
        previousState: State,
        viewModel: ConversationSettingsViewModel
    ) -> [SectionModel] {
            return [
                SectionModel(
                    model: .messageTrimming,
                    elements: [
                        SessionCell.Info(
                            id: .messageTrimming,
                            title: "conversationsMessageTrimmingTrimCommunities".localized(),
                            subtitle: "conversationsMessageTrimmingTrimCommunitiesDescription".localized(),
                            trailingAccessory: .toggle(
                                state.trimOpenGroupMessagesOlderThanSixMonths,
                                oldValue: previousState.trimOpenGroupMessagesOlderThanSixMonths,
                                accessibility: Accessibility(
                                    identifier: "Trim Communities - Switch"
                                )
                            ),
                            onTap: { [dependencies = viewModel.dependencies] in
                                dependencies.setAsync(
                                    .trimOpenGroupMessagesOlderThanSixMonths,
                                    !state.trimOpenGroupMessagesOlderThanSixMonths
                                )
                            }
                        )
                    ]
                ),
                SectionModel(
                    model: .audioMessages,
                    elements: [
                        SessionCell.Info(
                            id: .audioMessages,
                            title: "conversationsAutoplayAudioMessage".localized(),
                            subtitle: "conversationsAutoplayAudioMessageDescription".localized(),
                            trailingAccessory: .toggle(
                                state.shouldAutoPlayConsecutiveAudioMessages,
                                oldValue: previousState.shouldAutoPlayConsecutiveAudioMessages,
                                accessibility: Accessibility(
                                    identifier: "Autoplay Audio Messages - Switch"
                                )
                            ),
                            onTap: { [dependencies = viewModel.dependencies] in
                                dependencies.setAsync(
                                    .shouldAutoPlayConsecutiveAudioMessages,
                                    !state.shouldAutoPlayConsecutiveAudioMessages
                                )
                            }
                        )
                    ]
                ),
                SectionModel(
                    model: .blockedContacts,
                    elements: [
                        SessionCell.Info(
                            id: .blockedContacts,
                            title: "conversationsBlockedContacts".localized(),
                            subtitle: "blockedContactsManageDescription".localized(),
                            trailingAccessory: .icon(
                                .chevronRight,
                                shouldFill: true ,
                                shouldFollowIconSize: true
                            ),
                            onTap: { [weak viewModel, dependencies = viewModel.dependencies] in
                                viewModel?.transitionToScreen(
                                    SessionTableViewController(viewModel: BlockedContactsViewModel(using: dependencies))
                                )
                            }
                        )
                    ]
                )
            ]
        }
}
