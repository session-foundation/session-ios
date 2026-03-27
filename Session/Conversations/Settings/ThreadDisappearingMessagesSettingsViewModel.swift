// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit
import SessionNetworkingKit

class ThreadDisappearingMessagesSettingsViewModel: SessionTableViewModel, NavigatableStateHolder, ObservableTableSource {
    typealias TableItem = String
    
    public let dependencies: Dependencies
    public let navigatableState: NavigatableState = NavigatableState()
    public let state: TableDataState<Section, TableItem> = TableDataState()
    public let observableState: ObservableTableSourceState<Section, TableItem> = ObservableTableSourceState()
    
    @MainActor @Published private(set) var internalState: State
    private var observationTask: Task<Void, Never>?
    
    // MARK: - Initialization
    
    @MainActor init(
        threadId: String,
        threadVariant: SessionThread.Variant,
        currentUserRole: GroupMember.Role?,
        config: DisappearingMessagesConfiguration,
        using dependencies: Dependencies
    ) {
        self.dependencies = dependencies
        self.internalState = State(
            threadId: threadId,
            threadVariant: threadVariant,
            isNoteToSelf: (threadId == dependencies[cache: .general].sessionId.hexString),
            currentUserRole: currentUserRole,
            originalConfig: config,
            config: config,
            userSessionId: dependencies[cache: .general].sessionId
        )
        
        self.observationTask = ObservationBuilder
            .initialValue(self.internalState)
            .using(dependencies: dependencies)
            .query(ThreadDisappearingMessagesSettingsViewModel.queryState)
            .assign { [weak self] updatedState in
                guard let self = self else { return }
                
                // FIXME: To slightly reduce the size of the changes this new observation mechanism is currently wired into the old SessionTableViewController observation mechanism, we should refactor it so everything uses the new mechanism
                self.internalState = updatedState
                self.pendingTableDataSubject.send(updatedState.sections(viewModel: self))
            }
    }
    
    deinit {
        observationTask?.cancel()
    }
    
    // MARK: - Config
    
    public enum Section: SessionTableSection {
        case type
        case timerLegacy
        case timerDisappearAfterSend
        case timerDisappearAfterRead
        case noteToSelf
        case group
        
        var title: String? {
            switch self {
                case .type: return "disappearingMessagesDeleteType".localized()
                // We need to keep these although the titles of them are the same
                // because we need them to trigger timer section to refresh when
                // the user selects different disappearing messages type
                case .timerLegacy, .timerDisappearAfterSend, .timerDisappearAfterRead: return "disappearingMessagesTimer".localized()
                case .noteToSelf: return nil
                case .group: return nil
            }
        }
        
        var style: SessionTableSectionStyle { return .titleRoundedContent }
        
        var footer: String? {
            switch self {
                case .group: 
                    return "\("disappearingMessagesDescription".localized())\n\("disappearingMessagesOnlyAdmins".localized())"
                default: return nil
            }
        }
    }
    
    public struct ThreadDisappearingMessagesSettingsEvent: Hashable {
        let config: DisappearingMessagesConfiguration
    }
    
    // MARK: - State
    
    struct State: ObservableKeyProvider {
        let threadId: String
        let threadVariant: SessionThread.Variant
        let isNoteToSelf: Bool
        let currentUserRole: GroupMember.Role?
        let originalConfig: DisappearingMessagesConfiguration
        let config: DisappearingMessagesConfiguration
        let userSessionId: SessionId
        
        @MainActor public func sections(viewModel: ThreadDisappearingMessagesSettingsViewModel) -> [SectionModel] {
            ThreadDisappearingMessagesSettingsViewModel.sections(state: self, viewModel: viewModel)
        }
        
        var observedKeys: Set<ObservableKey> {
            var result: Set<ObservableKey> = [
                .updateScreen(ThreadDisappearingMessagesSettingsViewModel.self)
            ]
                
            if threadVariant == .group {
                result.insert(contentsOf: [
                    .groupMemberUpdated(profileId: userSessionId.hexString, threadId: threadId),
                    .anyGroupMemberDeleted(threadId: threadId)
                ])
            }
            
            return result
        }
    }
    
    @Sendable private static func queryState(
        previousState: State,
        events: [ObservedEvent],
        isInitialQuery: Bool,
        using dependencies: Dependencies
    ) async -> State {
        var currentUserRole: GroupMember.Role? = previousState.currentUserRole
        var config: DisappearingMessagesConfiguration = previousState.config
        
        if previousState.threadVariant == .group {
            let hasMembershipEvent: Bool = events.contains {
                switch $0.key.generic {
                    case .groupMemberUpdated, .anyGroupMemberDeleted: return true
                    default: return false
                }
            }
            
            if isInitialQuery || hasMembershipEvent {
                currentUserRole = try? await dependencies[singleton: .storage].read { db in
                    try GroupMember
                        .filter(GroupMember.Columns.groupId == previousState.threadId)
                        .filter(GroupMember.Columns.profileId == previousState.userSessionId.hexString)
                        .fetchAll(db)
                        .map { $0.role }
                        .sorted()
                        .last
                }
            }
        }
        
        if let event: ThreadDisappearingMessagesSettingsEvent = events.first?.value as? ThreadDisappearingMessagesSettingsEvent {
            config = event.config
        }
        
        return State(
            threadId: previousState.threadId,
            threadVariant: previousState.threadVariant,
            isNoteToSelf: previousState.isNoteToSelf,
            currentUserRole: currentUserRole,
            originalConfig: previousState.originalConfig,
            config: config,
            userSessionId: previousState.userSessionId
        )
    }
    
    // MARK: - Content
    
    let title: String = "disappearingMessages".localized()
    @MainActor lazy var subtitle: String? = {
        switch (internalState.threadVariant, internalState.isNoteToSelf) {
            case (.contact, false): return "disappearingMessagesDescription1".localized()
            case (.group, _), (.legacyGroup, _): return "disappearingMessagesDisappearAfterSendDescription".localized()
            case (.community, _): return nil
            case (_, true): return "disappearingMessagesDescription".localized()
        }
    }()
    
    lazy var footerButtonInfo: AnyPublisher<SessionButton.Info?, Never> = $internalState
        .map { state -> Bool in
            /// Need to explicitly compare values because 'lastChangeTimestampMs' will differ
            return (
                state.config.isEnabled != state.originalConfig.isEnabled ||
                state.config.durationSeconds != state.originalConfig.durationSeconds ||
                state.config.type != state.originalConfig.type
            )
        }
        .removeDuplicates()
        .map { [weak self] shouldShowConfirmButton -> SessionButton.Info? in
            guard shouldShowConfirmButton else { return nil }
            
            return SessionButton.Info(
                style: .bordered,
                title: "set".localized(),
                isEnabled: true,
                accessibility: Accessibility(
                    identifier: "Set button",
                    label: "Set button"
                ),
                minWidth: 110,
                onTap: {
                    Task(priority: .userInitiated) { [weak self] in
                        await self?.saveChanges()
                        self?.dismissScreen()
                    }
                }
            )
        }
        .eraseToAnyPublisher()
    
    private static func sections(state: State, viewModel: ThreadDisappearingMessagesSettingsViewModel) -> [SectionModel] {
        switch (state.threadVariant, state.isNoteToSelf) {
            case (.contact, false):
                return [
                    SectionModel(
                        model: .type,
                        elements: [
                            SessionCell.Info(
                                id: "off".localized(),
                                title: "off".localized(),
                                trailingAccessory: .radio(
                                    isSelected: !state.config.isEnabled,
                                    accessibility: Accessibility(
                                        identifier: "Off - Radio"
                                    )
                                ),
                                accessibility: Accessibility(
                                    identifier: "Disable disappearing messages (Off option)",
                                    label: "Disable disappearing messages (Off option)"
                                ),
                                onTap: { [dependencies = viewModel.dependencies] in
                                    dependencies.notifyAsync(
                                        key: .updateScreen(ThreadDisappearingMessagesSettingsViewModel.self),
                                        value: ThreadDisappearingMessagesSettingsEvent(
                                            config: state.config.with(
                                                isEnabled: false,
                                                durationSeconds: DisappearingMessagesConfiguration.DefaultDuration.off.seconds
                                            )
                                        )
                                    )
                                }
                            ),
                            SessionCell.Info(
                                id: "disappearingMessagesDisappearAfterRead".localized(),
                                title: "disappearingMessagesDisappearAfterRead".localized(),
                                subtitle: "disappearingMessagesDisappearAfterReadDescription".localized(),
                                trailingAccessory: .radio(
                                    isSelected: (
                                        state.config.isEnabled &&
                                        state.config.type == .disappearAfterRead
                                    ),
                                    accessibility: Accessibility(
                                        identifier: "Disappear After Read - Radio"
                                    )
                                ),
                                accessibility: Accessibility(
                                    identifier: "Disappear after read option",
                                    label: "Disappear after read option"
                                ),
                                onTap: { [dependencies = viewModel.dependencies] in
                                    let updatedConfig: DisappearingMessagesConfiguration
                                    
                                    switch (state.originalConfig.isEnabled, state.originalConfig.type) {
                                        case (true, .disappearAfterRead):
                                            updatedConfig = state.originalConfig
                                            
                                        default:
                                            updatedConfig = state.config.with(
                                                isEnabled: true,
                                                durationSeconds: DisappearingMessagesConfiguration.DefaultDuration.disappearAfterRead.seconds,
                                                type: .disappearAfterRead
                                            )
                                    }
                                    
                                    dependencies.notifyAsync(
                                        key: .updateScreen(ThreadDisappearingMessagesSettingsViewModel.self),
                                        value: ThreadDisappearingMessagesSettingsEvent(
                                            config: updatedConfig
                                        )
                                    )
                                }
                            ),
                            SessionCell.Info(
                                id: "disappearingMessagesDisappearAfterSend".localized(),
                                title: "disappearingMessagesDisappearAfterSend".localized(),
                                subtitle: "disappearingMessagesDisappearAfterSendDescription".localized(),
                                trailingAccessory: .radio(
                                    isSelected: (
                                        state.config.isEnabled &&
                                        state.config.type == .disappearAfterSend
                                    ),
                                    accessibility: Accessibility(
                                        identifier: "Disappear After Send - Radio"
                                    )
                                ),
                                accessibility: Accessibility(
                                    identifier: "Disappear after send option",
                                    label: "Disappear after send option"
                                ),
                                onTap: { [dependencies = viewModel.dependencies] in
                                    let updatedConfig: DisappearingMessagesConfiguration
                                    
                                    switch (state.originalConfig.isEnabled, state.originalConfig.type) {
                                        case (true, .disappearAfterSend):
                                            updatedConfig = state.originalConfig
                                            
                                        default:
                                            updatedConfig = state.config.with(
                                                isEnabled: true,
                                                durationSeconds: DisappearingMessagesConfiguration.DefaultDuration.disappearAfterSend.seconds,
                                                type: .disappearAfterSend
                                            )
                                    }
                                    
                                    dependencies.notifyAsync(
                                        key: .updateScreen(ThreadDisappearingMessagesSettingsViewModel.self),
                                        value: ThreadDisappearingMessagesSettingsEvent(
                                            config: updatedConfig
                                        )
                                    )
                                }
                            )
                        ].compactMap { $0 }
                    ),
                    (!state.config.isEnabled ? nil :
                        SectionModel(
                            model: (state.config.type == .disappearAfterSend ?
                                .timerDisappearAfterSend :
                                .timerDisappearAfterRead
                            ),
                            elements: DisappearingMessagesConfiguration
                                .validDurationsSeconds(
                                    state.config.type ?? .disappearAfterSend,
                                    using: viewModel.dependencies
                                )
                                .map { duration in
                                    let title: String = duration.formatted(format: .long)

                                    return SessionCell.Info(
                                        id: title,
                                        title: title,
                                        trailingAccessory: .radio(
                                            isSelected: (
                                                state.config.isEnabled &&
                                                state.config.durationSeconds == duration
                                            ),
                                            accessibility: Accessibility(
                                                identifier: "\(title) - Radio"
                                            )
                                        ),
                                        accessibility: Accessibility(
                                            identifier: "Time option",
                                            label: "Time option"
                                        ),
                                        onTap: { [dependencies = viewModel.dependencies] in
                                            dependencies.notifyAsync(
                                                key: .updateScreen(ThreadDisappearingMessagesSettingsViewModel.self),
                                                value: ThreadDisappearingMessagesSettingsEvent(
                                                    config: state.config.with(
                                                        durationSeconds: duration
                                                    )
                                                )
                                            )
                                        }
                                    )
                                }
                        )
                    )
                ].compactMap { $0 }
            
            case (.legacyGroup, _), (.group, _), (_, true):
                return [
                    SectionModel(
                        model: (state.isNoteToSelf ? .noteToSelf : .group),
                        elements: [
                            SessionCell.Info(
                                id: "off".localized(),
                                title: "off".localized(),
                                trailingAccessory: .radio(
                                    isSelected: !state.config.isEnabled,
                                    accessibility: Accessibility(
                                        identifier: "Off - Radio"
                                    )
                                ),
                                isEnabled: (
                                    state.isNoteToSelf ||
                                    state.currentUserRole == .admin
                                ),
                                accessibility: Accessibility(
                                    identifier: "Disable disappearing messages (Off option)",
                                    label: "Disable disappearing messages (Off option)"
                                ),
                                onTap: { [dependencies = viewModel.dependencies] in
                                    dependencies.notifyAsync(
                                        key: .updateScreen(ThreadDisappearingMessagesSettingsViewModel.self),
                                        value: ThreadDisappearingMessagesSettingsEvent(
                                            config: state.config.with(
                                                isEnabled: false,
                                                durationSeconds: DisappearingMessagesConfiguration.DefaultDuration.off.seconds
                                            )
                                        )
                                    )
                                }
                            )
                        ]
                        .compactMap { $0 }
                        .appending(
                            contentsOf: DisappearingMessagesConfiguration
                                .validDurationsSeconds(.disappearAfterSend, using: viewModel.dependencies)
                                .map { duration in
                                    let title: String = duration.formatted(format: .long)

                                    return SessionCell.Info(
                                        id: title,
                                        title: title,
                                        trailingAccessory: .radio(
                                            isSelected: (
                                                state.config.isEnabled &&
                                                state.config.durationSeconds == duration
                                            ),
                                            accessibility: Accessibility(
                                                identifier: "\(title) - Radio"
                                            )
                                        ),
                                        isEnabled: (state.isNoteToSelf || state.currentUserRole == .admin),
                                        accessibility: Accessibility(
                                            identifier: "Time option",
                                            label: "Time option"
                                        ),
                                        onTap: { [dependencies = viewModel.dependencies] in
                                            dependencies.notifyAsync(
                                                key: .updateScreen(ThreadDisappearingMessagesSettingsViewModel.self),
                                                value: ThreadDisappearingMessagesSettingsEvent(
                                                    config: state.config.with(
                                                        isEnabled: true,
                                                        durationSeconds: duration,
                                                        type: .disappearAfterSend
                                                    )
                                                )
                                            )
                                        }
                                    )
                                }
                        )
                    )
                ].compactMap { $0 }

            case (.community, _):
                return [] // Should not happen
        }
    }
    
    // MARK: - Functions
    
    @MainActor private func saveChanges() async {
        guard internalState.originalConfig != internalState.config else { return }
        
        /// Custom handle updated groups first (all logic is consolidated in the MessageSender extension
        let threadId: String = internalState.threadId
        let threadVariant: SessionThread.Variant = internalState.threadVariant
        let userSessionId: SessionId = internalState.userSessionId
        let updatedConfig: DisappearingMessagesConfiguration = internalState.config
        
        switch internalState.threadVariant {
            case .group:
                Task.detached(priority: .userInitiated) { [dependencies] in
                    try? await MessageSender.updateGroup(
                        groupSessionId: threadId,
                        disapperingMessagesConfig: updatedConfig,
                        using: dependencies
                    )
                }
            
            default: break
        }

        // Otherwise handle other conversation variants
        Task(priority: .userInitiated) { [dependencies] in
            try? await dependencies[singleton: .storage].write { db in
                // Update the local state
                try updatedConfig.upserted(db)
                
                let currentOffsetTimestampMs: UInt64 = dependencies.networkOffsetTimestampMs()
                let interactionId = try updatedConfig
                    .upserted(db)
                    .insertControlMessage(
                        db,
                        threadVariant: threadVariant,
                        authorId: userSessionId.hexString,
                        timestampMs: currentOffsetTimestampMs,
                        serverHash: nil,
                        serverExpirationTimestamp: nil,
                        using: dependencies
                    )?
                    .interactionId
                
                // Update libSession
                switch threadVariant {
                    case .contact:
                        try LibSession.update(
                            db,
                            sessionId: threadId,
                            disappearingMessagesConfig: updatedConfig,
                            using: dependencies
                        )
                        
                    case .group: break // Handled above
                    default: break
                }
                
                // Send a control message that the disappearing messages setting changed
                try MessageSender.send(
                    db,
                    message: ExpirationTimerUpdate()
                        .with(sentTimestampMs: UInt64(currentOffsetTimestampMs))
                        .with(updatedConfig),
                    interactionId: interactionId,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    using: dependencies
                )
                
                /// Notify of update
                db.addConversationEvent(
                    id: threadId,
                    variant: threadVariant,
                    type: .updated(.disappearingMessageConfiguration(updatedConfig))
                )
            }
        }
    }
}

extension String: @retroactive Differentiable {}
