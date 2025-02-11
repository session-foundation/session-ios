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
    
    // MARK: - Content
    
    let title: String = "disappearingMessages".localized()
    lazy var subtitle: String? = {
        switch (threadVariant, isNoteToSelf) {
            case (.contact, false): return "disappearingMessagesDescription1".localized()
            case (.group, _), (.legacyGroup, _): return "disappearingMessagesDisappearAfterSendDescription".localized()
            case (.community, _): return nil
            case (_, true): return "disappearingMessagesDescription".localized()
        }
    }()
    
    lazy var footerButtonInfo: AnyPublisher<SessionButton.Info?, Never> = shouldShowConfirmButton
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
        .subject(currentSelection)
        .map { [weak self, threadVariant, isNoteToSelf, config, currentUserIsClosedGroupMember, currentUserIsClosedGroupAdmin] currentSelection -> [SectionModel] in
            switch (threadVariant, isNoteToSelf) {
                case (.contact, false):
                    return [
                        SectionModel(
                            model: .type,
                            elements: [
                                SessionCell.Info(
                                    id: "off".localized(),
                                    title: "off".localized(),
                                    rightAccessory: .radio(
                                        isSelected: { (self?.currentSelection.value.isEnabled == false) },
                                        accessibility: Accessibility(
                                            identifier: "Off - Radio"
                                        )
                                    ),
                                    accessibility: Accessibility(
                                        identifier: "Disable disappearing messages (Off option)",
                                        label: "Disable disappearing messages (Off option)"
                                    ),
                                    onTap: {
                                        let updatedConfig: DisappearingMessagesConfiguration = currentSelection
                                            .with(
                                                isEnabled: false,
                                                durationSeconds: DisappearingMessagesConfiguration.DefaultDuration.off.seconds
                                            )
                                        self?.shouldShowConfirmButton.send(updatedConfig != config)
                                        self?.currentSelection.send(updatedConfig)
                                    }
                                ),
                                SessionCell.Info(
                                    id: "disappearingMessagesDisappearAfterRead".localized(),
                                    title: "disappearingMessagesDisappearAfterRead".localized(),
                                    subtitle: "disappearingMessagesDisappearAfterReadDescription".localized(),
                                    rightAccessory: .radio(
                                        isSelected: {
                                            (self?.currentSelection.value.isEnabled == true) &&
                                            (self?.currentSelection.value.type == .disappearAfterRead)
                                        },
                                        accessibility: Accessibility(
                                            identifier: "Disappear After Read - Radio"
                                        )
                                    ),
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
                                                    type: .disappearAfterRead
                                                )
                                        }()
                                        self?.shouldShowConfirmButton.send(updatedConfig != config)
                                        self?.currentSelection.send(updatedConfig)
                                    }
                                ),
                                SessionCell.Info(
                                    id: "disappearingMessagesDisappearAfterSend".localized(),
                                    title: "disappearingMessagesDisappearAfterSend".localized(),
                                    subtitle: "disappearingMessagesDisappearAfterSendDescription".localized(),
                                    rightAccessory: .radio(
                                        isSelected: {
                                            (self?.currentSelection.value.isEnabled == true) &&
                                            (self?.currentSelection.value.type == .disappearAfterSend)
                                        },
                                        accessibility: Accessibility(
                                            identifier: "Disappear After Send - Radio"
                                        )
                                    ),
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
                                                    type: .disappearAfterSend
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
                                model: (currentSelection.type == .disappearAfterSend ?
                                    .timerDisappearAfterSend :
                                    .timerDisappearAfterRead
                                ),
                                elements: DisappearingMessagesConfiguration
                                    .validDurationsSeconds(currentSelection.type ?? .disappearAfterSend)
                                    .map { duration in
                                        let title: String = duration.formatted(format: .long)

                                        return SessionCell.Info(
                                            id: title,
                                            title: title,
                                            rightAccessory: .radio(
                                                isSelected: {
                                                    (self?.currentSelection.value.isEnabled == true) &&
                                                    (self?.currentSelection.value.durationSeconds == duration)
                                                },
                                                accessibility: Accessibility(
                                                    identifier: "\(title) - Radio"
                                                )
                                            ),
                                            accessibility: Accessibility(
                                                identifier: "Time option",
                                                label: "Time option"
                                            ),
                                            onTap: {
                                                let updatedConfig: DisappearingMessagesConfiguration = currentSelection.with(durationSeconds: duration)
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
                        SectionModel(
                            model: (isNoteToSelf ? .noteToSelf : .group),
                            elements: [
                                SessionCell.Info(
                                    id: "off".localized(),
                                    title: "off".localized(),
                                    rightAccessory: .radio(
                                        isSelected: { (self?.currentSelection.value.isEnabled == false) },
                                        accessibility: Accessibility(
                                            identifier: "Off - Radio"
                                        )
                                    ),
                                    isEnabled: (
                                        isNoteToSelf ||
                                        currentUserIsClosedGroupAdmin == true
                                    ),
                                    accessibility: Accessibility(
                                        identifier: "Disable disappearing messages (Off option)",
                                        label: "Disable disappearing messages (Off option)"
                                    ),
                                    onTap: {
                                        let updatedConfig: DisappearingMessagesConfiguration = currentSelection
                                            .with(
                                                isEnabled: false,
                                                durationSeconds: DisappearingMessagesConfiguration.DefaultDuration.off.seconds
                                            )
                                        self?.shouldShowConfirmButton.send(updatedConfig != config)
                                        self?.currentSelection.send(updatedConfig)
                                    }
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
                                                },
                                                accessibility: Accessibility(
                                                    identifier: "\(title) - Radio"
                                                )
                                            ),
                                            isEnabled: (isNoteToSelf || currentUserIsClosedGroupAdmin == true),
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
                                                        isEnabled: true,
                                                        durationSeconds: duration,
                                                        type: .disappearAfterSend
                                                    )
                                                self?.shouldShowConfirmButton.send(updatedConfig != config)
                                                self?.currentSelection.send(updatedConfig)
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
    
    private func saveChanges() {
        let updatedConfig: DisappearingMessagesConfiguration = self.currentSelection.value

        guard self.config != updatedConfig else { return }

        dependencies.storage.writeAsync(using: dependencies) { [threadId, threadVariant, dependencies] db in
            let userPublicKey: String = getUserHexEncodedPublicKey(db, using: dependencies)
            let currentTimestampMs: Int64 = SnodeAPI.currentOffsetTimestampMs()
            
            let interactionId = try updatedConfig
                .saved(db)
                .insertControlMessage(
                    db,
                    threadVariant: threadVariant,
                    authorId: userPublicKey,
                    timestampMs: currentTimestampMs,
                    serverHash: nil,
                    serverExpirationTimestamp: nil
                )
            
            let expirationTimerUpdateMessage: ExpirationTimerUpdate = ExpirationTimerUpdate()
                .with(sentTimestamp: UInt64(currentTimestampMs))
                .with(updatedConfig)

            try MessageSender.send(
                db,
                message: expirationTimerUpdateMessage,
                interactionId: interactionId,
                threadId: threadId,
                threadVariant: threadVariant,
                using: dependencies
            )
        }
        
        // Contacts & legacy closed groups need to update the LibSession
        dependencies.storage.writeAsync(using: dependencies) { [threadId, threadVariant, dependencies] db in
            switch threadVariant {
                case .contact:
                    try LibSession.update(
                        db,
                        sessionId: threadId,
                        disappearingMessagesConfig: updatedConfig,
                        using: dependencies
                    )
                
                case .legacyGroup:
                    try LibSession.update(
                        db,
                        groupPublicKey: threadId,
                        disappearingConfig: updatedConfig,
                        using: dependencies
                    )
                    
                default: break
            }
        }
    }
}
