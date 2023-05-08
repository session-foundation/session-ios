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
        case timerDisappearAfterSend
        case timerDisappearAfterRead
        case noteToSelf
        case group
        
        var title: String? {
            switch self {
                case .type: return "DISAPPERING_MESSAGES_TYPE_TITLE".localized()
                case .timerDisappearAfterSend: return "DISAPPERING_MESSAGES_TIMER_TITLE".localized()
                case .timerDisappearAfterRead: return "DISAPPERING_MESSAGES_TIMER_TITLE".localized()
                case .noteToSelf: return nil
                case .group: return nil
            }
        }
        
        var style: SessionTableSectionStyle { return .title }
        
        var footer: String? {
            switch self {
                case .group: return "DISAPPERING_MESSAGES_GROUP_WARNING_ADMIN_ONLY".localized()
                default: return nil
            }
        }
    }
    
    public struct Item: Equatable, Hashable, Differentiable {
        let title: String
            
        public var differenceIdentifier: String { title }
    }
    
    // MARK: - Variables
    
    private let dependencies: Dependencies
    private let threadId: String
    private var isNoteToSelf: Bool
    private let threadVariant: SessionThread.Variant
    private let currentUserIsClosedGroupMember: Bool?
    private let currentUserIsClosedGroupAdmin: Bool?
    private let config: DisappearingMessagesConfiguration
    private var currentSelection: CurrentValueSubject<DisappearingMessagesConfiguration, Error>
    private var shouldShowConfirmButton: CurrentValueSubject<Bool, Never>
    
    // MARK: - Initialization
    
    init(
        dependencies: Dependencies = Dependencies(),
        threadId: String,
        threadVariant: SessionThread.Variant,
        currentUserIsClosedGroupMember: Bool?,
        currentUserIsClosedGroupAdmin: Bool?,
        config: DisappearingMessagesConfiguration
    ) {
        self.dependencies = dependencies
        self.threadId = threadId
        self.threadVariant = threadVariant
        self.isNoteToSelf = (threadId == getUserHexEncodedPublicKey())
        self.currentUserIsClosedGroupMember = currentUserIsClosedGroupMember
        self.currentUserIsClosedGroupAdmin = currentUserIsClosedGroupAdmin
        self.config = config
        self.currentSelection = CurrentValueSubject(config)
        self.shouldShowConfirmButton = CurrentValueSubject(false)
    }
    
    // MARK: - Content
    
    override var title: String { "DISAPPEARING_MESSAGES".localized() }
    override var subtitle: String? {
        guard Features.useNewDisappearingMessagesConfig else {
            return (isNoteToSelf ? nil : "DISAPPERING_MESSAGES_SUBTITLE_CONTACTS".localized())
        }
        
        if threadVariant == .contact && !isNoteToSelf {
            return "DISAPPERING_MESSAGES_SUBTITLE_CONTACTS".localized()
        }
        
        return "DISAPPERING_MESSAGES_SUBTITLE_GROUPS".localized()
    }
    
    private var _settingsData: [SectionModel] = []
    public override var settingsData: [SectionModel] { _settingsData }
    
    override var footerButtonInfo: AnyPublisher<SessionButton.Info?, Never> {
        self.shouldShowConfirmButton
            .removeDuplicates()
            .map { [weak self] shouldShowConfirmButton in
                guard shouldShowConfirmButton else { return nil }
                return SessionButton.Info(
                    style: .bordered,
                    title: "DISAPPERING_MESSAGES_SAVE_TITLE".localized(),
                    isEnabled: true,
                    accessibilityIdentifier: "Set button",
                    minWidth: 110,
                    onTap: {
                        self?.saveChanges()
                        self?.dismissScreen()
                    }
                )
            }
            .eraseToAnyPublisher()
    }
    
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
            .map { [weak self, threadVariant, isNoteToSelf, config, currentUserIsClosedGroupMember, currentUserIsClosedGroupAdmin] currentSelection in
                switch (threadVariant, isNoteToSelf) {
                    case (.contact, false):
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
                                        accessibilityIdentifier: "Off option",
                                        accessibilityLabel: "Off option",
                                        onTap: {
                                            let updatedConfig: DisappearingMessagesConfiguration = currentSelection
                                                .with(
                                                    isEnabled: false,
                                                    durationSeconds: 0,
                                                    type: nil,
                                                    lastChangeTimestampMs: SnodeAPI.currentOffsetTimestampMs()
                                                )
                                            self?.shouldShowConfirmButton.send(updatedConfig != config)
                                            self?.currentSelection.send(updatedConfig)
                                        }
                                    ),
                                    (Features.useNewDisappearingMessagesConfig ? nil :
                                        SessionCell.Info(
                                            id: Item(title: "DISAPPEARING_MESSAGES_TYPE_LEGACY_TITLE".localized()),
                                            title: "DISAPPEARING_MESSAGES_TYPE_LEGACY_TITLE".localized(),
                                            subtitle: "DISAPPEARING_MESSAGES_TYPE_LEGACY_DESCRIPTION".localized(),
                                            rightAccessory: .radio(
                                                isSelected: {
                                                    (self?.currentSelection.value.isEnabled == true) &&
                                                    !Features.useNewDisappearingMessagesConfig
                                                }
                                            ),
                                            onTap: {
                                                let updatedConfig: DisappearingMessagesConfiguration = currentSelection
                                                    .with(
                                                        isEnabled: true,
                                                        durationSeconds: DisappearingMessagesConfiguration
                                                            .DisappearingMessageType
                                                            .disappearAfterRead
                                                            .defaultDuration,
                                                        type: .disappearAfterRead, // Default for 1-1
                                                        lastChangeTimestampMs: SnodeAPI.currentOffsetTimestampMs()
                                                    )
                                                self?.shouldShowConfirmButton.send(updatedConfig != self?.config)
                                                self?.currentSelection.send(updatedConfig)
                                            }
                                        )
                                    ),
                                    SessionCell.Info(
                                        id: Item(title: "DISAPPERING_MESSAGES_TYPE_AFTER_READ_TITLE".localized()),
                                        title: "DISAPPERING_MESSAGES_TYPE_AFTER_READ_TITLE".localized(),
                                        subtitle: "DISAPPERING_MESSAGES_TYPE_AFTER_READ_DESCRIPTION".localized(),
                                        tintColor: (Features.useNewDisappearingMessagesConfig ?
                                            .textPrimary :
                                            .disabled
                                        ),
                                        rightAccessory: .radio(
                                            isSelected: {
                                                (self?.currentSelection.value.isEnabled == true) &&
                                                (self?.currentSelection.value.type == .disappearAfterRead) &&
                                                Features.useNewDisappearingMessagesConfig
                                            }
                                        ),
                                        isEnabled: Features.useNewDisappearingMessagesConfig,
                                        accessibilityIdentifier: "Disappear after read option",
                                        accessibilityLabel: "Disappear after read option",
                                        onTap: {
                                            let updatedConfig: DisappearingMessagesConfiguration = currentSelection
                                                .with(
                                                    isEnabled: true,
                                                    durationSeconds: DisappearingMessagesConfiguration
                                                        .DisappearingMessageType
                                                        .disappearAfterRead
                                                        .defaultDuration,
                                                    type: .disappearAfterRead,
                                                    lastChangeTimestampMs: SnodeAPI.currentOffsetTimestampMs()
                                                )
                                            self?.shouldShowConfirmButton.send(updatedConfig != config)
                                            self?.currentSelection.send(updatedConfig)
                                        }
                                    ),
                                    SessionCell.Info(
                                        id: Item(title: "DISAPPERING_MESSAGES_TYPE_AFTER_SEND_TITLE".localized()),
                                        title: "DISAPPERING_MESSAGES_TYPE_AFTER_SEND_TITLE".localized(),
                                        subtitle: "DISAPPERING_MESSAGES_TYPE_AFTER_SEND_DESCRIPTION".localized(),
                                        tintColor: (Features.useNewDisappearingMessagesConfig ?
                                            .textPrimary :
                                            .disabled
                                        ),
                                        rightAccessory: .radio(
                                            isSelected: {
                                                (self?.currentSelection.value.isEnabled == true) &&
                                                (self?.currentSelection.value.type == .disappearAfterSend) &&
                                                Features.useNewDisappearingMessagesConfig
                                            }
                                        ),
                                        isEnabled: Features.useNewDisappearingMessagesConfig,
                                        accessibilityIdentifier: "Disappear after send option",
                                        accessibilityLabel: "Disappear after send option",
                                        onTap: {
                                            let updatedConfig: DisappearingMessagesConfiguration = currentSelection
                                                .with(
                                                    isEnabled: true,
                                                    durationSeconds: DisappearingMessagesConfiguration
                                                        .DisappearingMessageType
                                                        .disappearAfterSend
                                                        .defaultDuration,
                                                    type: .disappearAfterSend,
                                                    lastChangeTimestampMs: SnodeAPI.currentOffsetTimestampMs()
                                                )
                                            self?.shouldShowConfirmButton.send(updatedConfig != config)
                                            self?.currentSelection.send(updatedConfig)
                                        }
                                    )
                                ].compactMap { $0 }
                            ),
                            (currentSelection.isEnabled == false ? nil :
                                SectionModel(
                                    model: (currentSelection.type == .disappearAfterSend ?
                                        .timerDisappearAfterSend :
                                        .timerDisappearAfterRead
                                    ),
                                    elements: DisappearingMessagesConfiguration
                                        .validDurationsSeconds(currentSelection.type ?? .disappearAfterSend)
                                        .map { duration in
                                            let title: String = duration.formatted(format: .long)

                                            return SessionCell.Info(
                                                id: Item(title: title),
                                                title: title,
                                                rightAccessory: .radio(
                                                    isSelected: {
                                                        (self?.currentSelection.value.isEnabled == true) &&
                                                        (self?.currentSelection.value.durationSeconds == duration)
                                                    }
                                                ),
                                                accessibilityIdentifier: "Time option",
                                                accessibilityLabel: "Time option",
                                                onTap: {
                                                    let updatedConfig: DisappearingMessagesConfiguration = currentSelection
                                                        .with(
                                                            durationSeconds: duration,
                                                            lastChangeTimestampMs: SnodeAPI.currentOffsetTimestampMs()
                                                        )
                                                    self?.shouldShowConfirmButton.send(updatedConfig != config)
                                                    self?.currentSelection.send(updatedConfig)
                                                }
                                            )
                                        }
                                )
                            )
                        ].compactMap { $0 }
                    
                    case (.closedGroup, _), (_, true):
                        return [
                            (Features.useNewDisappearingMessagesConfig ? nil :
                                SectionModel(
                                    model: .type,
                                    elements: [
                                        SessionCell.Info(
                                            id: Item(title: "DISAPPEARING_MESSAGES_OFF".localized()),
                                            title: "DISAPPEARING_MESSAGES_OFF".localized(),
                                            rightAccessory: .radio(
                                                isSelected: { (self?.currentSelection.value.isEnabled == false) }
                                            ),
                                            isEnabled: (
                                                isNoteToSelf ||
                                                currentUserIsClosedGroupMember == true
                                            ),
                                            accessibilityIdentifier: "Off option",
                                            accessibilityLabel: "Off option",
                                            onTap: {
                                                let updatedConfig: DisappearingMessagesConfiguration = currentSelection
                                                    .with(
                                                        isEnabled: false,
                                                        durationSeconds: 0,
                                                        type: nil,
                                                        lastChangeTimestampMs: SnodeAPI.currentOffsetTimestampMs()
                                                    )
                                                self?.shouldShowConfirmButton.send(updatedConfig != config)
                                                self?.currentSelection.send(updatedConfig)
                                            }
                                        ),
                                        SessionCell.Info(
                                            id: Item(title: "DISAPPEARING_MESSAGES_TYPE_LEGACY_TITLE".localized()),
                                            title: "DISAPPEARING_MESSAGES_TYPE_LEGACY_TITLE".localized(),
                                            subtitle: "DISAPPEARING_MESSAGES_TYPE_LEGACY_DESCRIPTION".localized(),
                                            rightAccessory: .radio(
                                                isSelected: {
                                                    (self?.currentSelection.value.isEnabled == true) &&
                                                    !Features.useNewDisappearingMessagesConfig
                                                }
                                            ),
                                            isEnabled: (
                                                isNoteToSelf ||
                                                currentUserIsClosedGroupMember == true
                                            ),
                                            onTap: {
                                                let updatedConfig: DisappearingMessagesConfiguration = currentSelection
                                                    .with(
                                                        isEnabled: true,
                                                        durationSeconds: DisappearingMessagesConfiguration
                                                            .DisappearingMessageType
                                                            .disappearAfterSend
                                                            .defaultDuration,
                                                        type: DisappearingMessagesConfiguration.DisappearingMessageType.disappearAfterSend, // Default for closed group & note to self
                                                        lastChangeTimestampMs: SnodeAPI.currentOffsetTimestampMs()
                                                    )
                                                self?.shouldShowConfirmButton.send(updatedConfig != config)
                                                self?.currentSelection.send(updatedConfig)
                                            }
                                        ),
                                        SessionCell.Info(
                                            id: Item(title: "DISAPPERING_MESSAGES_TYPE_AFTER_SEND_TITLE".localized()),
                                            title: "DISAPPERING_MESSAGES_TYPE_AFTER_SEND_TITLE".localized(),
                                            subtitle: "DISAPPERING_MESSAGES_TYPE_AFTER_SEND_DESCRIPTION".localized(),
                                            tintColor: (Features.useNewDisappearingMessagesConfig ?
                                                .textPrimary :
                                                .disabled
                                            ),
                                            rightAccessory: .radio(
                                                isSelected: {
                                                    (self?.currentSelection.value.isEnabled == true) &&
                                                    (self?.currentSelection.value.type == .disappearAfterSend) &&
                                                    Features.useNewDisappearingMessagesConfig
                                                }
                                            ),
                                            isEnabled: (
                                                Features.useNewDisappearingMessagesConfig && (
                                                    isNoteToSelf ||
                                                    currentUserIsClosedGroupMember == true
                                                )
                                            ),
                                            onTap: {
                                                let updatedConfig: DisappearingMessagesConfiguration = currentSelection
                                                    .with(
                                                        isEnabled: true,
                                                        durationSeconds: DisappearingMessagesConfiguration
                                                            .DisappearingMessageType
                                                            .disappearAfterSend
                                                            .defaultDuration,
                                                        type: .disappearAfterSend,
                                                        lastChangeTimestampMs: SnodeAPI.currentOffsetTimestampMs()
                                                    )
                                                self?.shouldShowConfirmButton.send(updatedConfig != config)
                                                self?.currentSelection.send(updatedConfig)
                                            }
                                        )
                                    ]
                                )
                            ),
                            (!Features.useNewDisappearingMessagesConfig && currentSelection.isEnabled == false ? nil :
                                SectionModel(
                                    model: {
                                        guard Features.useNewDisappearingMessagesConfig else {
                                            return (currentSelection.type == .disappearAfterSend ?
                                                .timerDisappearAfterSend :
                                                .timerDisappearAfterRead
                                            )
                                        }

                                        return (isNoteToSelf ? .noteToSelf : .group)
                                    }(),
                                    elements: [
                                        (!Features.useNewDisappearingMessagesConfig ? nil :
                                            SessionCell.Info(
                                                id: Item(title: "DISAPPEARING_MESSAGES_OFF".localized()),
                                                title: "DISAPPEARING_MESSAGES_OFF".localized(),
                                                rightAccessory: .radio(
                                                    isSelected: { (self?.currentSelection.value.isEnabled == false) }
                                                ),
                                                isEnabled: (
                                                    isNoteToSelf ||
                                                    currentUserIsClosedGroupMember == true
                                                ),
                                                accessibilityIdentifier: "Off option",
                                                accessibilityLabel: "Off option",
                                                onTap: {
                                                    let updatedConfig: DisappearingMessagesConfiguration = currentSelection
                                                        .with(
                                                            isEnabled: false,
                                                            durationSeconds: 0,
                                                            type: nil,
                                                            lastChangeTimestampMs: SnodeAPI.currentOffsetTimestampMs()
                                                        )
                                                    self?.shouldShowConfirmButton.send(updatedConfig != config)
                                                    self?.currentSelection.send(updatedConfig)
                                                }
                                            )
                                        )
                                    ]
                                    .compactMap { $0 }
                                    .appending(
                                        contentsOf: DisappearingMessagesConfiguration
                                            .validDurationsSeconds(currentSelection.type ?? .disappearAfterSend)
                                            .map { duration in
                                                let title: String = duration.formatted(format: .long)

                                                return SessionCell.Info(
                                                    id: Item(title: title),
                                                    title: title,
                                                    rightAccessory: .radio(
                                                        isSelected: {
                                                            (self?.currentSelection.value.isEnabled == true) &&
                                                            (self?.currentSelection.value.durationSeconds == duration)
                                                        }
                                                    ),
                                                    isEnabled: (
                                                        isNoteToSelf ||
                                                        currentUserIsClosedGroupMember == true
                                                    ),
                                                    accessibilityIdentifier: "Time option",
                                                    accessibilityLabel: "Time option",
                                                    onTap: {
                                                        // If the new disappearing messages config feature flag isn't
                                                        // enabled then the 'isEnabled' and 'type' values are set via
                                                        // the first section so pass `nil` values to keep the existing
                                                        // setting
                                                        let updatedConfig: DisappearingMessagesConfiguration = currentSelection
                                                            .with(
                                                                isEnabled: (Features.useNewDisappearingMessagesConfig ?
                                                                    true :
                                                                    nil
                                                                ),
                                                                durationSeconds: duration,
                                                                type: (Features.useNewDisappearingMessagesConfig ?
                                                                    .disappearAfterSend :
                                                                   nil
                                                                ),
                                                                lastChangeTimestampMs: SnodeAPI.currentOffsetTimestampMs()
                                                            )
                                                        self?.shouldShowConfirmButton.send(updatedConfig != config)
                                                        self?.currentSelection.send(updatedConfig)
                                                    }
                                                )
                                            }
                                    )
                                )
                            )
                        ].compactMap { $0 }
                        
                    case (.openGroup, _):
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

        dependencies.storage.writeAsync { db in
            guard let thread: SessionThread = try SessionThread.fetchOne(db, id: threadId) else {
                return
            }

            _ = try updatedConfig.saved(db)
            
            _ = try Interaction
                .filter(Interaction.Columns.threadId == threadId)
                .filter(Interaction.Columns.variant == Interaction.Variant.infoDisappearingMessagesUpdate)
                .deleteAll(db)
            
            let currentOffsetTimestampMs: Int64 = SnodeAPI.currentOffsetTimestampMs()
            
            let interaction: Interaction = try Interaction(
                threadId: threadId,
                authorId: getUserHexEncodedPublicKey(db),
                variant: .infoDisappearingMessagesUpdate,
                body: updatedConfig.messageInfoString(with: nil, isPreviousOff: !self.config.isEnabled),
                timestampMs: currentOffsetTimestampMs,
                expiresInSeconds: updatedConfig.isEnabled ? nil : self.config.durationSeconds,
                expiresStartedAtMs: (!updatedConfig.isEnabled && self.config.type == .disappearAfterSend) ? Double(currentOffsetTimestampMs) : nil
            )
            .inserted(db)
            
            let duration: UInt32? = {
                guard !Features.useNewDisappearingMessagesConfig else { return nil }
                return UInt32(floor(updatedConfig.isEnabled ? updatedConfig.durationSeconds : 0))
            }()

            try MessageSender.send(
                db,
                message: ExpirationTimerUpdate(
                    syncTarget: nil,
                    duration: duration
                ),
                interactionId: interaction.id,
                in: thread
            )
        }
    }
}
