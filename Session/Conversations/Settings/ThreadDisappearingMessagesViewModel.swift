// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

class ThreadDisappearingMessagesViewModel: SessionTableViewModel<ThreadDisappearingMessagesViewModel.NavButton, ThreadDisappearingMessagesViewModel.Section, ThreadDisappearingMessagesViewModel.Item> {
    // MARK: - Config
    
    enum NavButton: Equatable {
        case save
    }
    
    public enum Section: SessionTableSection {
        case type
        case timer
        case timerWithOff
        
        var title: String? {
            switch self {
                case .type: return "DISAPPERING_MESSAGES_TYPE_TITLE".localized()
                case .timer: return "DISAPPERING_MESSAGES_TIMER_TITLE".localized()
                case .timerWithOff: return nil
            }
        }
        
        var style: SessionTableSectionStyle { return .title }
    }
    
    public struct Item: Equatable, Hashable, Differentiable {
        let title: String
            
        public var differenceIdentifier: String { title }
    }
    
    // MARK: - Variables
    
    private let dependencies: Dependencies
    private let threadId: String
    private let threadVariant: SessionThread.Variant
    private let config: DisappearingMessagesConfiguration
    private var currentSelection: CurrentValueSubject<DisappearingMessagesConfiguration, Error>
    
    // MARK: - Initialization
    
    init(
        dependencies: Dependencies = Dependencies(),
        threadId: String,
        threadVariant: SessionThread.Variant,
        config: DisappearingMessagesConfiguration
    ) {
        self.dependencies = dependencies
        self.threadId = threadId
        self.threadVariant = threadVariant
        self.config = config
        self.currentSelection = CurrentValueSubject(self.config)
    }
    
    // MARK: - Content
    
    override var title: String { "DISAPPEARING_MESSAGES".localized() }
    var subtitle: String { threadVariant == .contact ? "DISAPPERING_MESSAGES_SUBTITLE_CONTACTS".localized() : "DISAPPERING_MESSAGES_SUBTITLE_GROUPS".localized() }
    
    private var _settingsData: [SectionModel] = []
    public override var settingsData: [SectionModel] { _settingsData }
    
    public override var observableSettingsData: ObservableData { _observableSettingsData }
    
    /// This is all the data the screen needs to populate itself, please see the following link for tips to help optimise
    /// performance https://github.com/groue/GRDB.swift#valueobservation-performance
    ///
    /// **Note:** This observation will be triggered twice immediately (and be de-duped by the `removeDuplicates`)
    /// this is due to the behaviour of `ValueConcurrentObserver.asyncStartObservation` which triggers it's own
    /// fetch (after the ones in `ValueConcurrentObserver.asyncStart`/`ValueConcurrentObserver.syncStart`)
    /// just in case the database has changed between the two reads - unfortunately it doesn't look like there is a way to prevent this
    private lazy var _observableSettingsData: ObservableData = {
        self.currentSelection
            .map { [weak self] currentSelection in
                guard let threadVariant = self?.threadVariant else { return [] }
                
                switch threadVariant {
                    case .contact:
                        return [
                            SectionModel(
                                model: .type,
                                elements: [
                                    SessionCell.Info(
                                        id: Item(title: "DISAPPEARING_MESSAGES_OFF".localized()),
                                        title: "DISAPPEARING_MESSAGES_OFF".localized(),
                                        rightAccessory: .radio(
                                            isSelected: { (self?.currentSelection.value.isEnabled == false) }
                                        ),
                                        onTap: {
                                            let updatedConfig: DisappearingMessagesConfiguration = currentSelection
                                                .with(
                                                    isEnabled: false,
                                                    durationSeconds: 0,
                                                    type: nil
                                                )
                                            self?.currentSelection.send(updatedConfig)
                                        }
                                    ),
                                    SessionCell.Info(
                                        id: Item(title: "DISAPPERING_MESSAGES_TYPE_AFTER_READ_TITLE".localized()),
                                        title: "DISAPPERING_MESSAGES_TYPE_AFTER_READ_TITLE".localized(),
                                        subtitle: "DISAPPERING_MESSAGES_TYPE_AFTER_READ_DESCRIPTION".localized(),
                                        rightAccessory: .radio(
                                            isSelected: { (self?.currentSelection.value.isEnabled == true) && (self?.currentSelection.value.type == .disappearAfterRead) }
                                        ),
                                        onTap: {
                                            let updatedConfig: DisappearingMessagesConfiguration = currentSelection
                                                .with(
                                                    isEnabled: true,
                                                    durationSeconds: (24 * 60 * 60),
                                                    type: DisappearingMessagesConfiguration.DisappearingMessageType.disappearAfterRead
                                                )
                                            self?.currentSelection.send(updatedConfig)
                                        }
                                    ),
                                    SessionCell.Info(
                                        id: Item(title: "DISAPPERING_MESSAGES_TYPE_AFTER_SEND_TITLE".localized()),
                                        title: "DISAPPERING_MESSAGES_TYPE_AFTER_SEND_TITLE".localized(),
                                        subtitle: "DISAPPERING_MESSAGES_TYPE_AFTER_SEND_DESCRIPTION".localized(),
                                        rightAccessory: .radio(
                                            isSelected: { (self?.currentSelection.value.isEnabled == true) && (self?.currentSelection.value.type == .disappearAfterSend) }
                                        ),
                                        onTap: {
                                            let updatedConfig: DisappearingMessagesConfiguration = currentSelection
                                                .with(
                                                    isEnabled: true,
                                                    durationSeconds: (24 * 60 * 60),
                                                    type: DisappearingMessagesConfiguration.DisappearingMessageType.disappearAfterSend
                                                )
                                            self?.currentSelection.send(updatedConfig)
                                        }
                                    )
                                ]
                            )
                        ].appending(
                            (currentSelection.isEnabled == false) ? nil :
                                SectionModel(
                                    model: .timer,
                                    elements: DisappearingMessagesConfiguration
                                        .validDurationsSeconds(.disappearAfterRead)
                                        .map { duration in
                                            let title: String = duration.formatted(format: .long)
                                            
                                            return SessionCell.Info(
                                                id: Item(title: title),
                                                title: title,
                                                rightAccessory: .radio(
                                                    isSelected: { (self?.currentSelection.value.isEnabled == true) && (self?.currentSelection.value.durationSeconds == duration) }
                                                ),
                                                onTap: {
                                                    let updatedConfig: DisappearingMessagesConfiguration = currentSelection
                                                        .with(
                                                            durationSeconds: duration
                                                        )
                                                    self?.currentSelection.send(updatedConfig)
                                                }
                                            )
                                        }
                                )
                        )
                    case .closedGroup:
                        return [
                            SectionModel(
                                model: .timerWithOff,
                                elements: [
                                    SessionCell.Info(
                                        id: Item(title: "DISAPPEARING_MESSAGES_OFF".localized()),
                                        title: "DISAPPEARING_MESSAGES_OFF".localized(),
                                        rightAccessory: .radio(
                                            isSelected: { (self?.currentSelection.value.isEnabled == false) }
                                        ),
                                        onTap: {
                                            let updatedConfig: DisappearingMessagesConfiguration = currentSelection
                                                .with(
                                                    isEnabled: false,
                                                    durationSeconds: 0,
                                                    type: nil
                                                )
                                            self?.currentSelection.send(updatedConfig)
                                        }
                                    )
                                ].appending(
                                    contentsOf: DisappearingMessagesConfiguration
                                        .validDurationsSeconds(.disappearAfterRead)
                                        .map { duration in
                                            let title: String = duration.formatted(format: .long)
                                            
                                            return SessionCell.Info(
                                                id: Item(title: title),
                                                title: title,
                                                rightAccessory: .radio(
                                                    isSelected: { (self?.currentSelection.value.isEnabled == true) && (self?.currentSelection.value.durationSeconds == duration) }
                                                ),
                                                onTap: {
                                                    let updatedConfig: DisappearingMessagesConfiguration = currentSelection
                                                        .with(
                                                            isEnabled: true,
                                                            durationSeconds: duration,
                                                            type: .disappearAfterRead
                                                        )
                                                    self?.currentSelection.send(updatedConfig)
                                                }
                                            )
                                        }
                                )
                            )
                        ]
                    case . openGroup:
                        return [] // Should not happen
                }
            }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }()
    // MARK: - Functions

    public override func updateSettings(_ updatedSettings: [SectionModel]) {
        self._settingsData = updatedSettings
    }
    
    private func saveChanges() {
        let threadId: String = self.threadId
        let updatedConfig: DisappearingMessagesConfiguration = self.currentSelection.value

        guard self.config != updatedConfig else { return }

//        dependencies.storage.writeAsync { db in
//            guard let thread: SessionThread = try SessionThread.fetchOne(db, id: threadId) else {
//                return
//            }
//
//            let config: DisappearingMessagesConfiguration = try DisappearingMessagesConfiguration
//                .fetchOne(db, id: threadId)
//                .defaulting(to: DisappearingMessagesConfiguration.defaultWith(threadId))
//                .with(
//                    isEnabled: (currentSelection != 0),
//                    durationSeconds: currentSelection
//                )
//                .saved(db)
//
//            let interaction: Interaction = try Interaction(
//                threadId: threadId,
//                authorId: getUserHexEncodedPublicKey(db),
//                variant: .infoDisappearingMessagesUpdate,
//                body: config.messageInfoString(with: nil),
//                timestampMs: Int64(floor(Date().timeIntervalSince1970 * 1000))
//            )
//            .inserted(db)
//
//            try MessageSender.send(
//                db,
//                message: ExpirationTimerUpdate(
//                    syncTarget: nil,
//                    duration: UInt32(floor(updatedConfig.isEnabled ? updatedConfig.durationSeconds : 0))
//                ),
//                interactionId: interaction.id,
//                in: thread
//            )
//        }
    }
}
