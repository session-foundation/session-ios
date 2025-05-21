// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit
import SessionSnodeKit

class ThreadNotificationSettingsViewModel: SessionTableViewModel, NavigatableStateHolder, ObservableTableSource {
    public let dependencies: Dependencies
    public let navigatableState: NavigatableState = NavigatableState()
    public let state: TableDataState<Section, TableItem> = TableDataState()
    public let observableState: ObservableTableSourceState<Section, TableItem> = ObservableTableSourceState()
    
    private let threadViewModel: SessionThreadViewModel
    private var threadViewModelSubject: CurrentValueSubject<SessionThreadViewModel, Never>
    
    // MARK: - Initialization
    
    init(
        threadViewModel: SessionThreadViewModel,
        using dependencies: Dependencies
    ) {
        self.dependencies = dependencies
        self.threadViewModel = threadViewModel
        self.threadViewModelSubject = CurrentValueSubject(threadViewModel)
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
    
    // MARK: - Content
    
    let title: String = "sessionNotifications".localized()
    
    lazy var footerButtonInfo: AnyPublisher<SessionButton.Info?, Never> = threadViewModelSubject
        .map { [threadViewModel] updatedThreadViewModel -> Bool in
            // Need to explicitly compare values because 'lastChangeTimestampMs' will differ
            return (
                updatedThreadViewModel.threadOnlyNotifyForMentions != threadViewModel.threadOnlyNotifyForMentions ||
                updatedThreadViewModel.threadMutedUntilTimestamp != threadViewModel.threadMutedUntilTimestamp
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
                    self?.saveChanges()
                    self?.dismissScreen()
                }
            )
        }
        .eraseToAnyPublisher()
    
    lazy var observation: TargetObservation = ObservationBuilder
        .subject(threadViewModelSubject)
        .compactMap { [weak self] threadViewModel -> [SectionModel]? in self?.content(threadViewModel) }
            
    private func content(_ threadViewModel: SessionThreadViewModel) -> [SectionModel] {
        let notificationTypeSection = SectionModel(
            model: .type,
            elements: [
                SessionCell.Info(
                    id: .allMessages,
                    leadingAccessory: .icon(.volume2),
                    title: "notificationsAllMessages".localized(),
                    trailingAccessory: .radio(
                        isSelected: (threadViewModel.threadOnlyNotifyForMentions != true && threadViewModel.threadMutedUntilTimestamp == nil),
                        accessibility: Accessibility(
                            identifier: "All messages - Radio"
                        )
                    ),
                    accessibility: Accessibility(
                        identifier: "All messages notification setting",
                        label: "All messages"
                    ),
                    onTap: { [weak self] in
                        self?.threadViewModelSubject.send(
                            threadViewModel.with(
                                threadMutedUntilTimestamp: nil
                            ).with(
                                threadOnlyNotifyForMentions: false
                            )
                        )
                    }
                ),
                
                SessionCell.Info(
                    id: .mentionsOnly,
                    leadingAccessory: .icon(.atSign),
                    title: "notificationsMentionsOnly".localized(),
                    trailingAccessory: .radio(
                        isSelected: (threadViewModel.threadOnlyNotifyForMentions == true),
                        accessibility: Accessibility(
                            identifier: "Mentions only - Radio"
                        )
                    ),
                    accessibility: Accessibility(
                        identifier: "Mentions only notification setting",
                        label: "Mentions only"
                    ),
                    onTap: { [weak self] in
                        self?.threadViewModelSubject.send(
                            threadViewModel.with(
                                threadMutedUntilTimestamp: nil
                            ).with(
                                threadOnlyNotifyForMentions: true
                            )
                        )
                    }
                ),
                
                SessionCell.Info(
                    id: .mute,
                    leadingAccessory: .icon(.volumeOff),
                    title: "notificationsMute".localized(),
                    trailingAccessory: .radio(
                        isSelected: (threadViewModel.threadMutedUntilTimestamp != nil),
                        accessibility: Accessibility(
                            identifier: "Mute - Radio"
                        )
                    ),
                    accessibility: Accessibility(
                        identifier: "\(ThreadSettingsViewModel.self).mute",
                        label: "Mute notifications"
                    ),
                    onTap: { [weak self] in
                        self?.threadViewModelSubject.send(
                            threadViewModel.with(
                                threadMutedUntilTimestamp: Date.distantFuture.timeIntervalSince1970
                            ).with(
                                threadOnlyNotifyForMentions: false
                            )
                        )
                    }
                )
            ].compactMap { $0 }
        )
        
        return [notificationTypeSection]
    }
    
    // MARK: - Functions
    
    private func saveChanges() {
        let threadViewModel: SessionThreadViewModel = self.threadViewModelSubject.value
        
        guard self.threadViewModel != threadViewModel else { return }
        
        dependencies[singleton: .storage].writeAsync { db in
            try SessionThread
                .filter(id: threadViewModel.threadId)
                .updateAll(
                    db,
                    SessionThread.Columns.onlyNotifyForMentions
                        .set(to: threadViewModel.threadOnlyNotifyForMentions),
                    SessionThread.Columns.mutedUntilTimestamp
                        .set(to: threadViewModel.threadMutedUntilTimestamp)
                )
        }
    }
}
