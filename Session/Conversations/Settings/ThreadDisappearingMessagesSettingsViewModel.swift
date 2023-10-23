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
    private var isNoteToSelf: Bool
    private let currentUserIsClosedGroupMember: Bool?
    private let currentUserIsClosedGroupAdmin: Bool?
    private let config: DisappearingMessagesConfiguration
    private var currentSelection: CurrentValueSubject<DisappearingMessagesConfiguration, Error>
    private var shouldShowConfirmButton: CurrentValueSubject<Bool, Never>
    
    // MARK: - Initialization
    
    init(
        threadId: String,
        threadVariant: SessionThread.Variant,
        currentUserIsClosedGroupMember: Bool?,
        currentUserIsClosedGroupAdmin: Bool?,
        config: DisappearingMessagesConfiguration,
        using dependencies: Dependencies = Dependencies()
    ) {
        self.dependencies = dependencies
        self.threadId = threadId
        self.threadVariant = threadVariant
        self.isNoteToSelf = (threadId == getUserHexEncodedPublicKey(using: dependencies))
        self.currentUserIsClosedGroupMember = currentUserIsClosedGroupMember
        self.currentUserIsClosedGroupAdmin = currentUserIsClosedGroupAdmin
        self.config = config
        self.currentSelection = CurrentValueSubject(config)
        self.shouldShowConfirmButton = CurrentValueSubject(false)
    }
    
    // MARK: - Config
    
    enum NavItem: Equatable {
        case save
    }
    
    public enum Section: SessionTableSection {
        case type
        case timer
        case noteToSelf
        case group
        
        var title: String? {
            switch self {
                case .type: return "DISAPPERING_MESSAGES_TYPE_TITLE".localized()
                case .timer: return "DISAPPERING_MESSAGES_TIMER_TITLE".localized()
                case .noteToSelf: return nil
                case .group: return nil
            }
        }
        
        var style: SessionTableSectionStyle { return .titleRoundedContent }
        
        var footer: String? {
            switch self {
                case .group: return "DISAPPERING_MESSAGES_GROUP_WARNING_ADMIN_ONLY".localized()
                default: return nil
            }
        }
    }
    
    // MARK: - Content
    
    let title: String = "DISAPPEARING_MESSAGES".localized()
    lazy var subtitle: String? = {
        guard Features.useNewDisappearingMessagesConfig else {
            return (isNoteToSelf ? nil : "DISAPPERING_MESSAGES_SUBTITLE_CONTACTS".localized())
        }
        
        if threadVariant == .contact && !isNoteToSelf {
            return "DISAPPERING_MESSAGES_SUBTITLE_CONTACTS".localized()
        }
        
        return "DISAPPERING_MESSAGES_SUBTITLE_GROUPS".localized()
    }()
    
    lazy var footerButtonInfo: AnyPublisher<SessionButton.Info?, Never> = shouldShowConfirmButton
        .removeDuplicates()
        .map { [weak self] shouldShowConfirmButton in
            guard shouldShowConfirmButton else { return nil }
            
            return SessionButton.Info(
                style: .bordered,
                title: "DISAPPERING_MESSAGES_SAVE_TITLE".localized(),
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
        .subject(currentSelection)
        .map { [weak self, threadVariant, isNoteToSelf, config, currentUserIsClosedGroupMember, currentUserIsClosedGroupAdmin] currentSelection -> [SectionModel] in
            switch (threadVariant, isNoteToSelf) {
                case (.contact, false):
                    return [
                        SectionModel(
                            model: .type,
                            elements: [
                                SessionCell.Info(
                                    id: "DISAPPEARING_MESSAGES_OFF".localized(),
                                    title: "DISAPPEARING_MESSAGES_OFF".localized(),
                                    rightAccessory: .radio(
                                        isSelected: { (self?.currentSelection.value.isEnabled == false) }
                                    ),
                                    accessibility: Accessibility(
                                        identifier: "Disable disappearing messages (Off option)",
                                        label: "Disable disappearing messages (Off option)"
                                    ),
                                    onTap: {
                                        let updatedConfig: DisappearingMessagesConfiguration = currentSelection
                                            .with(
                                                isEnabled: false,
                                                durationSeconds: DisappearingMessagesConfiguration.DefaultDuration.off.seconds,
                                                lastChangeTimestampMs: SnodeAPI.currentOffsetTimestampMs()
                                            )
                                        self?.shouldShowConfirmButton.send(updatedConfig != config)
                                        self?.currentSelection.send(updatedConfig)
                                    }
                                ),
                                (Features.useNewDisappearingMessagesConfig ? nil :
                                    SessionCell.Info(
                                        id: "DISAPPEARING_MESSAGES_TYPE_LEGACY_TITLE".localized(),
                                        title: "DISAPPEARING_MESSAGES_TYPE_LEGACY_TITLE".localized(),
                                        subtitle: "DISAPPEARING_MESSAGES_TYPE_LEGACY_DESCRIPTION".localized(),
                                        rightAccessory: .radio(
                                            isSelected: {
                                                (self?.currentSelection.value.isEnabled == true) &&
                                                !Features.useNewDisappearingMessagesConfig
                                            }
                                        ),
                                        onTap: {
                                            let updatedConfig: DisappearingMessagesConfiguration = {
                                                if (config.isEnabled == true && config.type == .disappearAfterRead) {
                                                    return config
                                                }
                                                return currentSelection
                                                    .with(
                                                        isEnabled: true,
                                                        durationSeconds: DisappearingMessagesConfiguration.DefaultDuration.legacy.seconds,
                                                        type: .disappearAfterRead, // Default for 1-1
                                                        lastChangeTimestampMs: SnodeAPI.currentOffsetTimestampMs()
                                                    )
                                            }()
                                            self?.shouldShowConfirmButton.send(updatedConfig != config)
                                            self?.currentSelection.send(updatedConfig)
                                        }
                                    )
                                ),
                                SessionCell.Info(
                                    id: "DISAPPERING_MESSAGES_TYPE_AFTER_READ_TITLE".localized(),
                                    title: "DISAPPERING_MESSAGES_TYPE_AFTER_READ_TITLE".localized(),
                                    subtitle: "DISAPPERING_MESSAGES_TYPE_AFTER_READ_DESCRIPTION".localized(),
                                    rightAccessory: .radio(
                                        isSelected: {
                                            (self?.currentSelection.value.isEnabled == true) &&
                                            (self?.currentSelection.value.type == .disappearAfterRead) &&
                                            Features.useNewDisappearingMessagesConfig
                                        }
                                    ),
                                    styling: SessionCell.StyleInfo(
                                        tintColor: (Features.useNewDisappearingMessagesConfig ?
                                            .textPrimary :
                                            .disabled
                                        )
                                    ),
                                    isEnabled: Features.useNewDisappearingMessagesConfig,
                                    accessibility: Accessibility(
                                        identifier: "Disappear after read option",
                                        label: "Disappear after read option"
                                    ),
                                    onTap: {
                                        let updatedConfig: DisappearingMessagesConfiguration = {
                                            if (config.isEnabled == true && config.type == .disappearAfterRead) {
                                                return config
                                            }
                                            return currentSelection
                                                .with(
                                                    isEnabled: true,
                                                    durationSeconds: DisappearingMessagesConfiguration.DefaultDuration.disappearAfterRead.seconds,
                                                    type: .disappearAfterRead,
                                                    lastChangeTimestampMs: SnodeAPI.currentOffsetTimestampMs()
                                                )
                                        }()
                                        self?.shouldShowConfirmButton.send(updatedConfig != config)
                                        self?.currentSelection.send(updatedConfig)
                                    }
                                ),
                                SessionCell.Info(
                                    id: "DISAPPERING_MESSAGES_TYPE_AFTER_SEND_TITLE".localized(),
                                    title: "DISAPPERING_MESSAGES_TYPE_AFTER_SEND_TITLE".localized(),
                                    subtitle: "DISAPPERING_MESSAGES_TYPE_AFTER_SEND_DESCRIPTION".localized(),
                                    rightAccessory: .radio(
                                        isSelected: {
                                            (self?.currentSelection.value.isEnabled == true) &&
                                            (self?.currentSelection.value.type == .disappearAfterSend) &&
                                            Features.useNewDisappearingMessagesConfig
                                        }
                                    ),
                                    styling: SessionCell.StyleInfo(
                                        tintColor: (Features.useNewDisappearingMessagesConfig ?
                                            .textPrimary :
                                            .disabled
                                        )
                                    ),
                                    isEnabled: Features.useNewDisappearingMessagesConfig,
                                    accessibility: Accessibility(
                                        identifier: "Disappear after send option",
                                        label: "Disappear after send option"
                                    ),
                                    onTap: {
                                        let updatedConfig: DisappearingMessagesConfiguration = {
                                            if (config.isEnabled == true && config.type == .disappearAfterSend) {
                                                return config
                                            }
                                            return currentSelection
                                                .with(
                                                    isEnabled: true,
                                                    durationSeconds: DisappearingMessagesConfiguration.DefaultDuration.disappearAfterSend.seconds,
                                                    type: .disappearAfterSend,
                                                    lastChangeTimestampMs: SnodeAPI.currentOffsetTimestampMs()
                                                )
                                        }()
                                        self?.shouldShowConfirmButton.send(updatedConfig != config)
                                        self?.currentSelection.send(updatedConfig)
                                    }
                                )
                            ].compactMap { $0 }
                        ),
                        (currentSelection.isEnabled == false ? nil :
                            SectionModel(
                                model: .timer,
                                elements: DisappearingMessagesConfiguration
                                    .validDurationsSeconds({
                                        guard Features.useNewDisappearingMessagesConfig else { return .disappearAfterSend }
                                        return currentSelection.type ?? .disappearAfterSend
                                    }())
                                    .map { duration in
                                        let title: String = duration.formatted(format: .long)

                                        return SessionCell.Info(
                                            id: title,
                                            title: title,
                                            rightAccessory: .radio(
                                                isSelected: {
                                                    (self?.currentSelection.value.isEnabled == true) &&
                                                    (self?.currentSelection.value.durationSeconds == duration)
                                                }
                                            ),
                                            accessibility: Accessibility(
                                                identifier: "Time option",
                                                label: "Time option"
                                            ),
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

                case (.legacyGroup, _), (.group, _), (_, true):
                    return [
                        (Features.useNewDisappearingMessagesConfig ? nil :
                            SectionModel(
                                model: .type,
                                elements: [
                                    SessionCell.Info(
                                        id: "DISAPPEARING_MESSAGES_OFF".localized(),
                                        title: "DISAPPEARING_MESSAGES_OFF".localized(),
                                        rightAccessory: .radio(
                                            isSelected: { (self?.currentSelection.value.isEnabled == false) }
                                        ),
                                        isEnabled: (
                                            isNoteToSelf ||
                                            currentUserIsClosedGroupMember == true
                                        ),
                                        accessibility: Accessibility(
                                            identifier: "Disable disappearing messages (Off option)",
                                            label: "Disable disappearing messages (Off option)"
                                        ),
                                        onTap: {
                                            let updatedConfig: DisappearingMessagesConfiguration = currentSelection
                                                .with(
                                                    isEnabled: false,
                                                    durationSeconds: DisappearingMessagesConfiguration.DefaultDuration.off.seconds,
                                                    lastChangeTimestampMs: SnodeAPI.currentOffsetTimestampMs()
                                                )
                                            self?.shouldShowConfirmButton.send(updatedConfig != config)
                                            self?.currentSelection.send(updatedConfig)
                                        }
                                    ),
                                    SessionCell.Info(
                                        id: "DISAPPEARING_MESSAGES_TYPE_LEGACY_TITLE".localized(),
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
                                            let updatedConfig: DisappearingMessagesConfiguration = {
                                                if (config.isEnabled == true && config.type == .disappearAfterSend) {
                                                    return config
                                                }
                                                return currentSelection
                                                    .with(
                                                        isEnabled: true,
                                                        durationSeconds: DisappearingMessagesConfiguration.DefaultDuration.legacy.seconds,
                                                        type: .disappearAfterSend, // Default for closed group & note to self
                                                        lastChangeTimestampMs: SnodeAPI.currentOffsetTimestampMs()
                                                    )
                                            }()
                                            self?.shouldShowConfirmButton.send(updatedConfig != config)
                                            self?.currentSelection.send(updatedConfig)
                                        }
                                    ),
                                    SessionCell.Info(
                                        id: "DISAPPERING_MESSAGES_TYPE_AFTER_SEND_TITLE".localized(),
                                        title: "DISAPPERING_MESSAGES_TYPE_AFTER_SEND_TITLE".localized(),
                                        subtitle: "DISAPPERING_MESSAGES_TYPE_AFTER_SEND_DESCRIPTION".localized(),
                                        rightAccessory: .radio(isSelected: { false }),
                                        styling: SessionCell.StyleInfo(tintColor: .disabled),
                                        isEnabled: false
                                    )
                                ]
                            )
                        ),
                        (!Features.useNewDisappearingMessagesConfig && currentSelection.isEnabled == false ? nil :
                            SectionModel(
                                model: {
                                    guard Features.useNewDisappearingMessagesConfig else { return .timer }

                                    return (isNoteToSelf ? .noteToSelf : .group)
                                }(),
                                elements: [
                                    (!Features.useNewDisappearingMessagesConfig ? nil :
                                        SessionCell.Info(
                                            id: "DISAPPEARING_MESSAGES_OFF".localized(),
                                            title: "DISAPPEARING_MESSAGES_OFF".localized(),
                                            rightAccessory: .radio(
                                                isSelected: { (self?.currentSelection.value.isEnabled == false) }
                                            ),
                                            isEnabled: (
                                                isNoteToSelf ||
                                                currentUserIsClosedGroupMember == true
                                            ),
                                            accessibility: Accessibility(
                                                identifier: "Disable disappearing messages (Off option)",
                                                label: "Disable disappearing messages (Off option)"
                                            ),
                                            onTap: {
                                                let updatedConfig: DisappearingMessagesConfiguration = currentSelection
                                                    .with(
                                                        isEnabled: false,
                                                        durationSeconds: DisappearingMessagesConfiguration.DefaultDuration.off.seconds,
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
                                        .validDurationsSeconds(.disappearAfterSend)
                                        .map { duration in
                                            let title: String = duration.formatted(format: .long)

                                            return SessionCell.Info(
                                                id: title,
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
                                                accessibility: Accessibility(
                                                    identifier: "Time option",
                                                    label: "Time option"
                                                ),
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

                case (.community, _):
                    return [] // Should not happen
            }
        }
    
    // MARK: - Functions
    
    private func saveChanges() {
        let updatedConfig: DisappearingMessagesConfiguration = self.currentSelection.value

        guard self.config != updatedConfig else { return }

        dependencies.storage.writeAsync(using: dependencies) { [threadId, threadVariant, dependencies] db in
            _ = try updatedConfig.saved(db)
            
            _ = try Interaction
                .filter(Interaction.Columns.threadId == threadId)
                .filter(Interaction.Columns.variant == Interaction.Variant.infoDisappearingMessagesUpdate)
                .deleteAll(db)
            
            let currentOffsetTimestampMs: Int64 = SnodeAPI.currentOffsetTimestampMs()
            
            let interaction: Interaction = try Interaction(
                threadId: threadId,
                authorId: getUserHexEncodedPublicKey(db, using: dependencies),
                variant: .infoDisappearingMessagesUpdate,
                body: updatedConfig.messageInfoString(with: nil, isPreviousOff: !self.config.isEnabled),
                timestampMs: currentOffsetTimestampMs,
                expiresInSeconds: (updatedConfig.isEnabled ? nil : self.config.durationSeconds),
                expiresStartedAtMs: (!updatedConfig.isEnabled && self.config.type == .disappearAfterSend ? Double(currentOffsetTimestampMs) : nil)
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
                threadId: threadId,
                threadVariant: threadVariant,
                using: dependencies
            )
        }
        
        // Contacts & legacy closed groups need to update the SessionUtil
        dependencies.storage.writeAsync(using: dependencies) { [threadId, threadVariant] db in
            switch threadVariant {
                case .contact:
                    try SessionUtil
                        .update(
                            db,
                            sessionId: threadId,
                            disappearingMessagesConfig: updatedConfig
                        )
                
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
