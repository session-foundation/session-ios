// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Lucide
import SessionMessagingKit
import SessionUtilitiesKit
import SessionUIKit

extension ContextMenuVC {
    struct ExpirationInfo {
        let expiresStartedAtMs: Double?
        let expiresInSeconds: TimeInterval?
    }
    
    struct Action {
        let icon: UIImage?
        let title: String
        let feedback: String?
        let expirationInfo: ExpirationInfo?
        let themeColor: ThemeValue
        let actionType: ActionType
        let shouldDismissInfoScreen: Bool
        let accessibilityLabel: String?
        let work: @MainActor ((@MainActor () -> Void)?) -> Void
        
        enum ActionType {
            case emoji
            case emojiPlus
            case dismiss
            case generic
        }
        
        // MARK: - Initialization
        
        init(
            icon: UIImage? = nil,
            title: String = "",
            feedback: String? = nil,
            expirationInfo: ExpirationInfo? = nil,
            themeColor: ThemeValue = .textPrimary,
            actionType: ActionType = .generic,
            shouldDismissInfoScreen: Bool = false,
            accessibilityLabel: String? = nil,
            work: @escaping @MainActor ((@MainActor () -> Void)?) -> Void
        ) {
            self.icon = icon
            self.title = title
            self.feedback = feedback
            self.expirationInfo = expirationInfo
            self.themeColor = themeColor
            self.actionType = actionType
            self.shouldDismissInfoScreen = shouldDismissInfoScreen
            self.accessibilityLabel = accessibilityLabel
            self.work = work
        }
        
        // MARK: - Actions
        
        static func info(_ cellViewModel: MessageViewModel, _ delegate: ContextMenuActionDelegate?) -> Action {
            return Action(
                icon: UIImage(named: "ic_info"),
                title: "info".localized(),
                accessibilityLabel: "Message info"
            ) { _ in delegate?.info(cellViewModel) }
        }

        static func retry(_ cellViewModel: MessageViewModel, _ delegate: ContextMenuActionDelegate?) -> Action {
            return Action(
                icon: UIImage(systemName: "arrow.triangle.2.circlepath"),
                title: (cellViewModel.state == .failedToSync ?
                    "resync".localized() :
                    "resend".localized()
                ),
                accessibilityLabel: (cellViewModel.state == .failedToSync ? "Resync message" : "Resend message")
            ) { completion in delegate?.retry(cellViewModel, completion: completion) }
        }

        static func reply(_ cellViewModel: MessageViewModel, _ delegate: ContextMenuActionDelegate?) -> Action {
            return Action(
                icon: UIImage(named: "ic_reply"),
                title: "reply".localized(),
                shouldDismissInfoScreen: true,
                accessibilityLabel: "Reply to message"
            ) { completion in delegate?.reply(cellViewModel, completion: completion) }
        }

        static func copy(_ cellViewModel: MessageViewModel, _ delegate: ContextMenuActionDelegate?) -> Action {
            return Action(
                icon: UIImage(named: "ic_copy"),
                title: "copy".localized(),
                feedback: "copied".localized(),
                accessibilityLabel: "Copy text"
            ) { completion in delegate?.copy(cellViewModel, completion: completion) }
        }

        static func copySessionID(_ cellViewModel: MessageViewModel, _ delegate: ContextMenuActionDelegate?) -> Action {
            return Action(
                icon: UIImage(named: "ic_copy"),
                title: "accountIDCopy".localized(),
                feedback: "copied".localized(),
                accessibilityLabel: "Copy Session ID"
            ) { completion in delegate?.copySessionID(cellViewModel, completion: completion) }
        }

        static func delete(_ cellViewModel: MessageViewModel, _ delegate: ContextMenuActionDelegate?) -> Action {
            return Action(
                icon: Lucide.image(icon: .trash2, size: 24),
                title: "delete".localized(),
                expirationInfo: ExpirationInfo(
                    expiresStartedAtMs: cellViewModel.expiresStartedAtMs,
                    expiresInSeconds: cellViewModel.expiresInSeconds
                ),
                themeColor: .danger,
                shouldDismissInfoScreen: true,
                accessibilityLabel: "Delete message"
            ) { completion in delegate?.delete(cellViewModel, completion: completion) }
        }

        static func save(_ cellViewModel: MessageViewModel, _ delegate: ContextMenuActionDelegate?) -> Action {
            return Action(
                icon: UIImage(named: "ic_download"),
                title: "save".localized(),
                feedback: "saved".localized(),
                accessibilityLabel: "Save attachment"
            ) { completion in delegate?.save(cellViewModel, completion: completion) }
        }

        static func ban(_ cellViewModel: MessageViewModel, _ delegate: ContextMenuActionDelegate?) -> Action {
            return Action(
                icon: UIImage(named: "ic_user_round_ban")?.withRenderingMode(.alwaysTemplate),
                title: "banUser".localized(),
                themeColor: .danger,
                accessibilityLabel: "Ban user"
            ) { completion in delegate?.ban(cellViewModel, completion: completion) }
        }
        
        static func banAndDeleteAllMessages(_ cellViewModel: MessageViewModel, _ delegate: ContextMenuActionDelegate?) -> Action {
            return Action(
                icon: UIImage(named: "ic_user_round_ban")?.withRenderingMode(.alwaysTemplate),
                title: "banDeleteAll".localized(),
                themeColor: .danger,
                shouldDismissInfoScreen: true,
                accessibilityLabel: "Ban user and delete"
            ) { completion in delegate?.banAndDeleteAllMessages(cellViewModel, completion: completion) }
        }
        
        static func react(_ cellViewModel: MessageViewModel, _ emoji: EmojiWithSkinTones, _ delegate: ContextMenuActionDelegate?) -> Action {
            return Action(
                title: emoji.rawValue,
                actionType: .emoji
            ) { _ in delegate?.react(cellViewModel, with: emoji) }
        }
        
        static func emojiPlusButton(_ cellViewModel: MessageViewModel, _ delegate: ContextMenuActionDelegate?) -> Action {
            return Action(
                actionType: .emojiPlus,
                accessibilityLabel: "Add emoji"
            ) { _ in delegate?.showFullEmojiKeyboard(cellViewModel) }
        }
        
        static func dismiss(_ delegate: ContextMenuActionDelegate?) -> Action {
            return Action(
                actionType: .dismiss
            ) { _ in delegate?.contextMenuDismissed() }
        }
        
        static func select(_ cellViewModel: MessageViewModel, _ delegate: ContextMenuActionDelegate?) -> Action {
            return Action(
                icon: Lucide.image(icon: .circleCheck, size: 24),
                title: "select".localized(),
                accessibilityLabel: "Select message"
            ) { completion in delegate?.select(cellViewModel, completion: completion) }
        }
    }
    
    static func viewModelCanReply(_ cellViewModel: MessageViewModel, using dependencies: Dependencies) -> Bool {
        return (
            cellViewModel.threadVariant != .legacyGroup &&
            (
                cellViewModel.linkPreview == nil ||
                cellViewModel.linkPreview?.variant != .openGroupInvitation
            ) && (
                cellViewModel.variant == .standardIncoming || (
                    cellViewModel.variant == .standardOutgoing &&
                    cellViewModel.state != .failed &&
                    cellViewModel.state != .sending
                )
            )
        )
    }

    static func actions(
        for cellViewModel: MessageViewModel,
        in threadViewModel: SessionThreadViewModel,
        forMessageInfoScreen: Bool,
        delegate: ContextMenuActionDelegate?,
        using dependencies: Dependencies
    ) -> [Action]? {
        switch cellViewModel.variant {
            case ._legacyStandardIncomingDeleted, .standardIncomingDeleted, .standardIncomingDeletedLocally,
                .standardOutgoingDeleted, .standardOutgoingDeletedLocally, .infoCall,
                .infoScreenshotNotification, .infoMediaSavedNotification, .infoLegacyGroupCreated,
                .infoLegacyGroupUpdated, .infoLegacyGroupCurrentUserLeft, .infoGroupCurrentUserLeaving,
                .infoGroupCurrentUserErrorLeaving, .infoMessageRequestAccepted,
                .infoDisappearingMessagesUpdate, .infoGroupInfoInvited, .infoGroupInfoUpdated,
                .infoGroupMembersUpdated:
                // Let the user delete info messages and unsent messages
                return [ Action.delete(cellViewModel, delegate) ]
                
            case .standardOutgoing, .standardIncoming: break
        }
        
        var canSelect: Bool {
            guard cellViewModel.variant == .standardIncoming || (
                cellViewModel.variant == .standardOutgoing &&
                cellViewModel.state != .failed &&
                cellViewModel.state != .sending
            ) else {
                return false
            }
            
            return true && !forMessageInfoScreen
        }
        
        let canRetry: Bool = (
            cellViewModel.threadVariant != .legacyGroup &&
            cellViewModel.variant == .standardOutgoing && (
                cellViewModel.state == .failed || (
                    cellViewModel.threadVariant == .contact &&
                    cellViewModel.state == .failedToSync
                )
            )
        )
        let canCopy: Bool = (
            cellViewModel.cellType == .textOnlyMessage || (
                (
                    cellViewModel.cellType == .genericAttachment ||
                    cellViewModel.cellType == .mediaMessage
                ) &&
                (cellViewModel.attachments ?? []).count == 1 &&
                (cellViewModel.attachments ?? []).first?.isVisualMedia == true &&
                (cellViewModel.attachments ?? []).first?.isValid == true && (
                    (cellViewModel.attachments ?? []).first?.state == .downloaded ||
                    (cellViewModel.attachments ?? []).first?.state == .uploaded
                )
            )
        )
        let canSave: Bool = {
            switch cellViewModel.cellType {
                case .mediaMessage:
                    return (cellViewModel.attachments ?? [])
                        .filter { attachment in
                            attachment.isValid &&
                            attachment.isVisualMedia && (
                                attachment.state == .downloaded ||
                                attachment.state == .uploaded
                            )
                        }.isEmpty == false
                    
                case .audio, .genericAttachment:
                    return (cellViewModel.attachments ?? [])
                        .filter { attachment in
                            attachment.isValid && (
                                attachment.state == .downloaded ||
                                attachment.state == .uploaded
                            )
                        }.isEmpty == false
                    
                default: return false
            }
        }()
        let canCopySessionId: Bool = (
            cellViewModel.variant == .standardIncoming &&
            cellViewModel.threadVariant != .community
        )
        let canDelete: Bool = (MessageViewModel.DeletionBehaviours.deletionActions(
            for: [cellViewModel],
            with: threadViewModel,
            using: dependencies
        ) != nil)
        let canBan: Bool = (
            cellViewModel.threadVariant == .community &&
            dependencies[singleton: .openGroupManager].isUserModeratorOrAdmin(
                publicKey: threadViewModel.currentUserSessionId,
                for: threadViewModel.openGroupRoomToken,
                on: threadViewModel.openGroupServer,
                currentUserSessionIds: (threadViewModel.currentUserSessionIds ?? [])
            )
        )
        let shouldShowEmojiActions: Bool = {
            guard cellViewModel.threadVariant != .legacyGroup else { return false }
            
            if cellViewModel.threadVariant == .community {
                return (
                    !forMessageInfoScreen &&
                    dependencies[singleton: .openGroupManager].doesOpenGroupSupport(
                        capability: .reactions,
                        on: cellViewModel.threadOpenGroupServer
                    )
                )
            }
            return (threadViewModel.threadIsMessageRequest != true && !forMessageInfoScreen)
        }()
        
        let recentEmojis: [EmojiWithSkinTones] = {
            guard shouldShowEmojiActions else { return [] }
            
            return (threadViewModel.recentReactionEmoji ?? [])
                .compactMap { EmojiWithSkinTones(rawValue: $0) }
        }()
        let generatedActions: [Action] = [
            
            (canRetry ? Action.retry(cellViewModel, delegate) : nil),
            (canSelect ? Action.select(cellViewModel, delegate) : nil),
            (viewModelCanReply(cellViewModel, using: dependencies) ? Action.reply(cellViewModel, delegate) : nil),
            (canCopy ? Action.copy(cellViewModel, delegate) : nil),
            (canSave ? Action.save(cellViewModel, delegate) : nil),
            (canCopySessionId ? Action.copySessionID(cellViewModel, delegate) : nil),
            (canDelete ? Action.delete(cellViewModel, delegate) : nil),
            (canBan ? Action.ban(cellViewModel, delegate) : nil),
            (canBan ? Action.banAndDeleteAllMessages(cellViewModel, delegate) : nil),
            (forMessageInfoScreen ? nil : Action.info(cellViewModel, delegate)),
        ]
        .appending(
            contentsOf: (shouldShowEmojiActions ? recentEmojis : [])
                .map { Action.react(cellViewModel, $0, delegate) }
        )
        .appending(forMessageInfoScreen ? nil : Action.emojiPlusButton(cellViewModel, delegate))
        .compactMap { $0 }
        
        guard !generatedActions.isEmpty else { return [] }
        
        return generatedActions.appending(forMessageInfoScreen ? nil : Action.dismiss(delegate))
    }
    
    
    static func navigationActions(
        for cellViewModel: MessageViewModel,
        in threadViewModel: SessionThreadViewModel,
        delegate: ContextMenuActionDelegate?,
        using dependencies: Dependencies
    ) -> [Action]? {
        let canDelete: Bool = (MessageViewModel.DeletionBehaviours.deletionActions(
            for: [cellViewModel],
            with: threadViewModel,
            using: dependencies
        ) != nil)
        
        var showDelete: Bool {
            cellViewModel.attachments != nil && canDelete
        }
        
        var showCopy: Bool {
            cellViewModel.cellType == .textOnlyMessage
        }
        
        let generatedActions: [Action] = [
            (showCopy ? Action.copy(cellViewModel, delegate) : nil),
            (showDelete ? Action.delete(cellViewModel, delegate) : nil),
            Action.info(cellViewModel, delegate)
        ]
        .compactMap { $0 }
        
        return generatedActions
    }
}

// MARK: - Delegate

protocol ContextMenuActionDelegate {
    func info(_ cellViewModel: MessageViewModel)
    @MainActor func retry(_ cellViewModel: MessageViewModel, completion: (@MainActor () -> Void)?)
    func reply(_ cellViewModel: MessageViewModel, completion: (() -> Void)?)
    func copy(_ cellViewModel: MessageViewModel, completion: (() -> Void)?)
    func copySessionID(_ cellViewModel: MessageViewModel, completion: (() -> Void)?)
    func delete(_ cellViewModel: MessageViewModel, completion: (() -> Void)?)
    func save(_ cellViewModel: MessageViewModel, completion: (() -> Void)?)
    func ban(_ cellViewModel: MessageViewModel, completion: (() -> Void)?)
    func banAndDeleteAllMessages(_ cellViewModel: MessageViewModel, completion: (() -> Void)?)
    func react(_ cellViewModel: MessageViewModel, with emoji: EmojiWithSkinTones)
    func showFullEmojiKeyboard(_ cellViewModel: MessageViewModel)
    func contextMenuDismissed()
    func select(_ cellViewModel: MessageViewModel, completion: (() -> Void)?)
}
