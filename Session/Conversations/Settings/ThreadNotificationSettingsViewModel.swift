// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit
import SessionSnodeKit

@MainActor
class ThreadNotificationSettingsViewModel: SessionTableViewModel, NavigatableStateHolder, ObservableTableSource {
    public let dependencies: Dependencies
    public let navigatableState: NavigatableState = NavigatableState()
    public let state: TableDataState<Section, TableItem> = TableDataState()
    public let observableState: ObservableTableSourceState<Section, TableItem> = ObservableTableSourceState()
    
    private let threadId: String
    private let threadVariant: SessionThread.Variant
    
    /// This value is the current state of the view
    private(set) var internalState: State
    private var observationTask: Task<Void, Never>?
    
    // MARK: - Initialization
    
    init(
        threadId: String,
        threadVariant: SessionThread.Variant,
        threadOnlyNotifyForMentions: Bool?,
        threadMutedUntilTimestamp: TimeInterval?,
        using dependencies: Dependencies
    ) {
        self.dependencies = dependencies
        self.threadId = threadId
        self.threadVariant = threadVariant
        self.internalState = State.initialState(
            threadOnlyNotifyForMentions: threadOnlyNotifyForMentions,
            threadMutedUntilTimestamp: threadMutedUntilTimestamp
        )
        
        bindState()
    }
    
    // MARK: - Config
    
    public enum Section: SessionTableSection {
        case type
    }
    
    public enum TableItem: Differentiable {
        case allMessages
        case mentionsOnly
        case mute
    }
    
    public struct ThreadNotificationSettingsEvent: Hashable {
        let threadOnlyNotifyForMentions: Bool
        let threadMutedUntilTimestamp: TimeInterval?
    }
    
    // MARK: - Content
    
    public struct State: ObservableKeyProvider {
        let threadOnlyNotifyForMentions: Bool
        let threadMutedUntilTimestamp: TimeInterval?
        let hasChangedFromInitialState: Bool
        
        @MainActor public func sections(viewModel: ThreadNotificationSettingsViewModel) -> [SectionModel] {
            ThreadNotificationSettingsViewModel.sections(state: self, viewModel: viewModel)
        }
        
        public let observedKeys: Set<ObservableKey> = [
            .updateScreen(ThreadNotificationSettingsViewModel.self)
        ]
        
        static func initialState(
            threadOnlyNotifyForMentions: Bool?,
            threadMutedUntilTimestamp: TimeInterval?
        ) -> State {
            return State(
                threadOnlyNotifyForMentions: (threadOnlyNotifyForMentions == true),
                threadMutedUntilTimestamp: threadMutedUntilTimestamp,
                hasChangedFromInitialState: false
            )
        }
    }
    
    let title: String = "sessionNotifications".localized()
    
    private func bindState() {
        let initialState: State = self.internalState
        
        observationTask = ObservationBuilder
            .debounce(for: .never)
            .using(manager: dependencies[singleton: .observationManager])
            .query { previousState, events in
                /// Store mutable copies of the data to update
                let currentState: State = (previousState ?? initialState)
                var threadOnlyNotifyForMentions: Bool = currentState.threadOnlyNotifyForMentions
                var threadMutedUntilTimestamp: TimeInterval? = currentState.threadMutedUntilTimestamp
                
                if let event: ThreadNotificationSettingsEvent = events.first?.value as? ThreadNotificationSettingsEvent {
                    threadOnlyNotifyForMentions = event.threadOnlyNotifyForMentions
                    threadMutedUntilTimestamp = event.threadMutedUntilTimestamp
                }
                
                /// Generate the new state
                return State(
                    threadOnlyNotifyForMentions: threadOnlyNotifyForMentions,
                    threadMutedUntilTimestamp: threadMutedUntilTimestamp,
                    hasChangedFromInitialState: (
                        threadOnlyNotifyForMentions != initialState.threadOnlyNotifyForMentions ||
                        threadMutedUntilTimestamp != initialState.threadMutedUntilTimestamp
                    )
                )
            }
            .assign { [weak self] updatedState in
                guard let self = self else { return }
                
                // FIXME: To slightly reduce the size of the changes this new observation mechanism is currently wired into the old SessionTableViewController observation mechanism, we should refactor it so everything uses the new mechanism
                let oldState: State = self.internalState
                self.internalState = updatedState
                self.pendingTableDataSubject.send(updatedState.sections(viewModel: self))
            }
    }
    
    lazy var footerButtonInfo: AnyPublisher<SessionButton.Info?, Never> = observableState
        .pendingTableDataSubject
        .map { [weak self] _ -> SessionButton.Info? in
            return SessionButton.Info(
                style: .bordered,
                title: "set".localized(),
                isEnabled: (self?.internalState.hasChangedFromInitialState == true),
                accessibility: Accessibility(
                    identifier: "Set button",
                    label: "Set button"
                ),
                minWidth: 110,
                onTap: {
                    self?.saveChanges()
                    self?.dismissScreen()
                }
            )
        }
        .eraseToAnyPublisher()
            
    private static func sections(state: State, viewModel: ThreadNotificationSettingsViewModel) -> [SectionModel] {
        let notificationTypeSection = SectionModel(
            model: .type,
            elements: [
                SessionCell.Info(
                    id: .allMessages,
                    leadingAccessory: .icon(.volume2),
                    title: "notificationsAllMessages".localized(),
                    trailingAccessory: .radio(
                        isSelected: (
                            !state.threadOnlyNotifyForMentions &&
                            state.threadMutedUntilTimestamp == nil
                        ),
                        accessibility: Accessibility(
                            identifier: "All messages - Radio"
                        )
                    ),
                    accessibility: Accessibility(
                        identifier: "All messages notification setting",
                        label: "All messages"
                    ),
                    onTap: { [observationManager = viewModel.dependencies[singleton: .observationManager]] in
                        Task {
                            await observationManager.notify(
                                .updateScreen(ThreadNotificationSettingsViewModel.self),
                                value: ThreadNotificationSettingsEvent(
                                    threadOnlyNotifyForMentions: false,
                                    threadMutedUntilTimestamp: nil
                                ),
                                priority: .immediate
                            )
                        }
                    }
                ),
                
                SessionCell.Info(
                    id: .mentionsOnly,
                    leadingAccessory: .icon(.atSign),
                    title: "notificationsMentionsOnly".localized(),
                    trailingAccessory: .radio(
                        isSelected: state.threadOnlyNotifyForMentions,
                        accessibility: Accessibility(
                            identifier: "Mentions only - Radio"
                        )
                    ),
                    accessibility: Accessibility(
                        identifier: "Mentions only notification setting",
                        label: "Mentions only"
                    ),
                    onTap: { [observationManager = viewModel.dependencies[singleton: .observationManager]] in
                        Task {
                            await observationManager.notify(
                                .updateScreen(ThreadNotificationSettingsViewModel.self),
                                value: ThreadNotificationSettingsEvent(
                                    threadOnlyNotifyForMentions: true,
                                    threadMutedUntilTimestamp: nil
                                ),
                                priority: .immediate
                            )
                        }
                    }
                ),
                
                SessionCell.Info(
                    id: .mute,
                    leadingAccessory: .icon(.volumeOff),
                    title: "notificationsMute".localized(),
                    trailingAccessory: .radio(
                        isSelected: (state.threadMutedUntilTimestamp != nil),
                        accessibility: Accessibility(
                            identifier: "Mute - Radio"
                        )
                    ),
                    accessibility: Accessibility(
                        identifier: "\(ThreadSettingsViewModel.self).mute",
                        label: "Mute notifications"
                    ),
                    onTap: { [observationManager = viewModel.dependencies[singleton: .observationManager]] in
                        Task {
                            await observationManager.notify(
                                .updateScreen(ThreadNotificationSettingsViewModel.self),
                                value: ThreadNotificationSettingsEvent(
                                    threadOnlyNotifyForMentions: false,
                                    threadMutedUntilTimestamp: Date.distantFuture.timeIntervalSince1970
                                ),
                                priority: .immediate
                            )
                        }
                    }
                )
            ].compactMap { $0 }
        )
        
        return [notificationTypeSection]
    }
    
    // MARK: - Functions
    
    private func saveChanges() {
        guard internalState.hasChangedFromInitialState else { return }
        
        dependencies[singleton: .notificationsManager].updateSettings(
            threadId: threadId,
            threadVariant: threadVariant,
            mentionsOnly: (internalState.threadOnlyNotifyForMentions == true),
            mutedUntil: internalState.threadMutedUntilTimestamp
        )
    }
}
