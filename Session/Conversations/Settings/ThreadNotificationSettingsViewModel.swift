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
    struct ThreadNotificationSettings: Equatable {
        let threadOnlyNotifyForMentions: Bool?
        let threadMutedUntilTimestamp: TimeInterval?
    }
    
    public let dependencies: Dependencies
    public let navigatableState: NavigatableState = NavigatableState()
    public let state: TableDataState<Section, TableItem> = TableDataState()
    public let observableState: ObservableTableSourceState<Section, TableItem> = ObservableTableSourceState()
    
    private let threadId: String
    private let threadVariant: SessionThread.Variant
    private let threadNotificationSettings: ThreadNotificationSettings
    private var threadNotificationSettingsSubject: CurrentValueSubject<ThreadNotificationSettings, Never>
    
    // MARK: - Initialization
    
    init(
        threadId: String,
        threadVariant: SessionThread.Variant,
        threadNotificationSettings: ThreadNotificationSettings,
        using dependencies: Dependencies
    ) {
        self.dependencies = dependencies
        self.threadId = threadId
        self.threadVariant = threadVariant
        self.threadNotificationSettings = threadNotificationSettings
        self.threadNotificationSettingsSubject = CurrentValueSubject(threadNotificationSettings)
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
    
    lazy var footerButtonInfo: AnyPublisher<SessionButton.Info?, Never> = threadNotificationSettingsSubject
        .map { [threadNotificationSettings] updatedThreadNotificationSettings -> Bool in
            // Need to explicitly compare values because 'lastChangeTimestampMs' will differ
            return threadNotificationSettings != updatedThreadNotificationSettings
        }
        .removeDuplicates()
        .map { [weak self] shouldEnableConfirmButton -> SessionButton.Info? in
            return SessionButton.Info(
                style: .bordered,
                title: "set".localized(),
                isEnabled: shouldEnableConfirmButton,
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
        .subject(threadNotificationSettingsSubject)
        .compactMap { [weak self] threadNotificationSettings -> [SectionModel]? in self?.content(threadNotificationSettings) }
            
    private func content(_ threadNotificationSettings: ThreadNotificationSettings) -> [SectionModel] {
        let notificationTypeSection = SectionModel(
            model: .type,
            elements: [
                SessionCell.Info(
                    id: .allMessages,
                    leadingAccessory: .icon(.volume2),
                    title: "notificationsAllMessages".localized(),
                    trailingAccessory: .radio(
                        isSelected: (threadNotificationSettings.threadOnlyNotifyForMentions != true && threadNotificationSettings.threadMutedUntilTimestamp == nil),
                        accessibility: Accessibility(
                            identifier: "All messages - Radio"
                        )
                    ),
                    accessibility: Accessibility(
                        identifier: "All messages notification setting",
                        label: "All messages"
                    ),
                    onTap: { [weak self] in
                        self?.threadNotificationSettingsSubject.send(
                            ThreadNotificationSettings(
                                threadOnlyNotifyForMentions: false,
                                threadMutedUntilTimestamp: nil
                            )
                        )
                    }
                ),
                
                SessionCell.Info(
                    id: .mentionsOnly,
                    leadingAccessory: .icon(.atSign),
                    title: "notificationsMentionsOnly".localized(),
                    trailingAccessory: .radio(
                        isSelected: (threadNotificationSettings.threadOnlyNotifyForMentions == true),
                        accessibility: Accessibility(
                            identifier: "Mentions only - Radio"
                        )
                    ),
                    accessibility: Accessibility(
                        identifier: "Mentions only notification setting",
                        label: "Mentions only"
                    ),
                    onTap: { [weak self] in
                        self?.threadNotificationSettingsSubject.send(
                            ThreadNotificationSettings(
                                threadOnlyNotifyForMentions: true,
                                threadMutedUntilTimestamp: nil
                            )
                        )
                    }
                ),
                
                SessionCell.Info(
                    id: .mute,
                    leadingAccessory: .icon(.volumeOff),
                    title: "notificationsMute".localized(),
                    trailingAccessory: .radio(
                        isSelected: (threadNotificationSettings.threadMutedUntilTimestamp != nil),
                        accessibility: Accessibility(
                            identifier: "Mute - Radio"
                        )
                    ),
                    accessibility: Accessibility(
                        identifier: "\(ThreadSettingsViewModel.self).mute",
                        label: "Mute notifications"
                    ),
                    onTap: { [weak self] in
                        self?.threadNotificationSettingsSubject.send(
                            ThreadNotificationSettings(
                                threadOnlyNotifyForMentions: false,
                                threadMutedUntilTimestamp: Date.distantFuture.timeIntervalSince1970
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
        let updatedThreadNotificationSettings: ThreadNotificationSettings = self.threadNotificationSettingsSubject.value
        
        guard self.threadNotificationSettings != updatedThreadNotificationSettings else { return }
        
        dependencies[singleton: .notificationsManager].updateSettings(
            threadId: threadId,
            threadVariant: threadVariant,
            mentionsOnly: (updatedThreadNotificationSettings.threadOnlyNotifyForMentions == true),
            mutedUntil: updatedThreadNotificationSettings.threadMutedUntilTimestamp
        )
    }
}
