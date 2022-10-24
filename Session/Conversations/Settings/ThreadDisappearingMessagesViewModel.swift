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
        
        var title: String? {
            switch self {
                case .type: return "DISAPPERING_MESSAGES_TYPE_TITLE".localized()
                case .timer: return "DISAPPERING_MESSAGES_TIMER_TITLE".localized()
            }
        }
        
        var style: SessionTableSectionStyle { return .title }
    }
    
    public enum Item: Differentiable {
        case off
        case disappearAfterRead
        case disappearAfterSend
        case currentSetting
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
                return [
                    SectionModel(
                        model: .type,
                        elements: [
                            SessionCell.Info(
                                id: .off,
                                title: "DISAPPEARING_MESSAGES_OFF".localized(),
                                rightAccessory: .radio(
                                    isSelected: { (currentSelection.isEnabled == false) }
                                ),
                                onTap: {
//                                    let updatedConfig: DisappearingMessagesConfiguration = currentSelection
//                                        .with(
//                                            isEnabled: false,
//                                            durationSeconds: 0,
//                                            type: nil
//                                        )
//                                    self?.currentSelection.send(updatedConfig)
                                }
                            ),
                            SessionCell.Info(
                                id: .disappearAfterRead,
                                title: "DISAPPERING_MESSAGES_TYPE_AFTER_READ_TITLE".localized(),
                                subtitle: "DISAPPERING_MESSAGES_TYPE_AFTER_READ_DESCRIPTION".localized(),
                                rightAccessory: .radio(
                                    isSelected: { (currentSelection.type == DisappearingMessagesConfiguration.DisappearingMessageType.disappearAfterRead) }
                                ),
                                onTap: {
//                                    let updatedConfig: DisappearingMessagesConfiguration = currentSelection
//                                        .with(
//                                            isEnabled: true,
//                                            durationSeconds: (24 * 60 * 60),
//                                            type: DisappearingMessagesConfiguration.DisappearingMessageType.disappearAfterRead
//                                        )
//                                    self?.currentSelection.send(updatedConfig)
                                }
                            ),
                            SessionCell.Info(
                                id: .disappearAfterSend,
                                title: "DISAPPERING_MESSAGES_TYPE_AFTER_SEND_TITLE".localized(),
                                subtitle: "DISAPPERING_MESSAGES_TYPE_AFTER_SEND_DESCRIPTION".localized(),
                                rightAccessory: .radio(
                                    isSelected: { (currentSelection.type == DisappearingMessagesConfiguration.DisappearingMessageType.disappearAfterSend) }
                                ),
                                onTap: {
//                                    let updatedConfig: DisappearingMessagesConfiguration = currentSelection
//                                        .with(
//                                            isEnabled: true,
//                                            durationSeconds: (24 * 60 * 60),
//                                            type: DisappearingMessagesConfiguration.DisappearingMessageType.disappearAfterSend
//                                        )
//                                    self?.currentSelection.send(updatedConfig)
                                }
                            )
                        ]
                    )
                ].appending(
                    (currentSelection.isEnabled == false) ? nil :
                        SectionModel(
                            model: .timer,
                            elements: [
                                SessionCell.Info(
                                    id: .currentSetting,
                                    title: currentSelection.durationSeconds.formatted(format: .long),
                                    rightAccessory: .icon(
                                        UIImage(named: "ic_chevron_down")?
                                            .withRenderingMode(.alwaysTemplate)
                                    ),
                                    onTap: { }
                                )
                            ]
                        )
                )
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
        
        dependencies.storage.writeAsync { db in
            guard let thread: SessionThread = try SessionThread.fetchOne(db, id: threadId) else {
                return
            }
            
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
                timestampMs: Int64(floor(Date().timeIntervalSince1970 * 1000))
            )
            .inserted(db)
            
            try MessageSender.send(
                db,
                message: ExpirationTimerUpdate(
                    syncTarget: nil,
                    duration: UInt32(floor(updatedConfig.isEnabled ? updatedConfig.durationSeconds : 0))
                ),
                interactionId: interaction.id,
                in: thread
            )
        }
    }
}
