// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit
import SessionSnodeKit

class ThreadDisappearingMessagesSettingsViewModel: SessionTableViewModel, NavigationItemSource, NavigatableStateHolder, ObservableTableSource {
    typealias TableItem = String
    
    public let dependencies: Dependencies
    public let navigatableState: NavigatableState = NavigatableState()
    public let state: TableDataState<Section, TableItem> = TableDataState()
    public let observableState: ObservableTableSourceState<Section, TableItem> = ObservableTableSourceState()
    
    private let threadId: String
    private let threadVariant: SessionThread.Variant
    private let config: DisappearingMessagesConfiguration
    private var storedSelection: TimeInterval
    private var currentSelection: CurrentValueSubject<TimeInterval, Never>
    
    // MARK: - Initialization
    
    init(
        threadId: String,
        threadVariant: SessionThread.Variant,
        config: DisappearingMessagesConfiguration,
        using dependencies: Dependencies = Dependencies()
    ) {
        self.dependencies = dependencies
        self.threadId = threadId
        self.threadVariant = threadVariant
        self.config = config
        self.storedSelection = (config.isEnabled ? config.durationSeconds : 0)
        self.currentSelection = CurrentValueSubject(self.storedSelection)
    }
    
    // MARK: - Config
    
    enum NavItem: Equatable {
        case cancel
        case save
    }
    
    public enum Section: SessionTableSection {
        case content
    }
    
    // MARK: - Navigation
    
    lazy var leftNavItems: AnyPublisher<[SessionNavItem<NavItem>], Never> = [
        SessionNavItem(
            id: .cancel,
            systemItem: .cancel,
            accessibilityIdentifier: "Cancel button"
        ) { [weak self] in self?.dismissScreen() }
    ]

    lazy var rightNavItems: AnyPublisher<[SessionNavItem<NavItem>], Never> = currentSelection
        .removeDuplicates()
        .map { [weak self] currentSelection in (self?.storedSelection != currentSelection) }
        .map { [weak self, dependencies] isChanged in
            guard isChanged else { return [] }
            
            return [
                SessionNavItem(
                    id: .save,
                    systemItem: .save,
                    accessibilityIdentifier: "Save button"
                ) {
                    self?.saveChanges(using: dependencies)
                    self?.dismissScreen()
                }
            ]
        }
       .eraseToAnyPublisher()
    
    // MARK: - Content
    
    let title: String = "DISAPPEARING_MESSAGES".localized()
    
    lazy var observation: TargetObservation = ObservationBuilder
        .databaseObservation(self) { [dependencies, threadId = self.threadId] db -> SessionThreadViewModel? in
            let userPublicKey: String = getUserHexEncodedPublicKey(db, using: dependencies)
            
            return try SessionThreadViewModel
                .conversationSettingsQuery(threadId: threadId, userPublicKey: userPublicKey)
                .fetchOne(db)
        }
        .map { [weak self, config, dependencies, threadId = self.threadId] maybeThreadViewModel -> [SectionModel] in
            return [
                SectionModel(
                    model: .content,
                    elements: [
                        SessionCell.Info(
                            id: "DISAPPEARING_MESSAGES_OFF".localized(),
                            title: "DISAPPEARING_MESSAGES_OFF".localized(),
                            rightAccessory: .radio(
                                isSelected: { (self?.currentSelection.value == 0) }
                            ),
                            isEnabled: (
                                (
                                    maybeThreadViewModel?.threadVariant != .legacyGroup &&
                                    maybeThreadViewModel?.threadVariant != .group
                                ) ||
                                maybeThreadViewModel?.currentUserIsClosedGroupMember == true
                            ),
                            onTap: { self?.currentSelection.send(0) }
                        )
                    ].appending(
                        contentsOf: DisappearingMessagesConfiguration.validDurationsSeconds
                            .map { duration in
                                let title: String = duration.formatted(format: .long)
                                
                                return SessionCell.Info(
                                    id: title,
                                    title: title,
                                    rightAccessory: .radio(
                                        isSelected: { (self?.currentSelection.value == duration) }
                                    ),
                                    isEnabled: (
                                        (
                                            maybeThreadViewModel?.threadVariant != .legacyGroup &&
                                            maybeThreadViewModel?.threadVariant != .group
                                        ) ||
                                        maybeThreadViewModel?.currentUserIsClosedGroupMember == true
                                    ),
                                    onTap: { self?.currentSelection.send(duration) }
                                )
                            }
                    )
                )
            ]
        }
    
    // MARK: - Functions
    
    private func saveChanges(using dependencies: Dependencies = Dependencies()) {
        let threadId: String = self.threadId
        let threadVariant: SessionThread.Variant = self.threadVariant
        let currentSelection: TimeInterval = self.currentSelection.value
        let updatedConfig: DisappearingMessagesConfiguration = self.config
            .with(
                isEnabled: (currentSelection != 0),
                durationSeconds: currentSelection
            )
        
        guard self.config != updatedConfig else { return }
        
        dependencies.storage.writeAsync { db in
            let config: DisappearingMessagesConfiguration = try DisappearingMessagesConfiguration
                .fetchOne(db, id: threadId)
                .defaulting(to: DisappearingMessagesConfiguration.defaultWith(threadId))
                .with(
                    isEnabled: (currentSelection != 0),
                    durationSeconds: currentSelection
                )
                .saved(db)
            
            let interaction: Interaction = try Interaction(
                threadId: threadId,
                authorId: getUserHexEncodedPublicKey(db),
                variant: .infoDisappearingMessagesUpdate,
                body: config.messageInfoString(with: nil),
                timestampMs: SnodeAPI.currentOffsetTimestampMs()
            )
            .inserted(db)
            
            try MessageSender.send(
                db,
                message: ExpirationTimerUpdate(
                    syncTarget: nil,
                    duration: UInt32(floor(updatedConfig.isEnabled ? updatedConfig.durationSeconds : 0))
                ),
                interactionId: interaction.id,
                threadId: threadId,
                threadVariant: threadVariant,
                using: dependencies
            )
            
            // Legacy closed groups
            switch threadVariant {
                case .legacyGroup:
                    try SessionUtil
                        .update(
                            db,
                            groupPublicKey: threadId,
                            disappearingConfig: updatedConfig
                        )
                    
                default: break
            }
        }
    }
}
