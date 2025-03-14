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
        let expirationInfo: ExpirationInfo?
        let themeColor: ThemeValue
        let actionType: ActionType
        let accessibilityLabel: String?
        let work: () -> Void
        
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
            expirationInfo: ExpirationInfo? = nil,
            themeColor: ThemeValue = .textPrimary,
            actionType: ActionType = .generic,
            accessibilityLabel: String? = nil,
            work: @escaping () -> Void
        ) {
            self.icon = icon
            self.title = title
            self.expirationInfo = expirationInfo
            self.themeColor = themeColor
            self.actionType = actionType
            self.accessibilityLabel = accessibilityLabel
            self.work = work
        }
        
        // MARK: - Actions
        
        static func info(_ cellViewModel: MessageViewModel, _ delegate: ContextMenuActionDelegate?) -> Action {
            return Action(
                icon: UIImage(named: "ic_info"),
                title: "info".localized(),
                accessibilityLabel: "Message info"
            ) { delegate?.info(cellViewModel) }
        }

        static func retry(_ cellViewModel: MessageViewModel, _ delegate: ContextMenuActionDelegate?) -> Action {
            return Action(
                icon: UIImage(systemName: "arrow.triangle.2.circlepath"),
                title: (cellViewModel.state == .failedToSync ?
                    "resync".localized() :
                    "resend".localized()
                ),
                accessibilityLabel: (cellViewModel.state == .failedToSync ? "Resync message" : "Resend message")
            ) { delegate?.retry(cellViewModel) }
        }

        static func reply(_ cellViewModel: MessageViewModel, _ delegate: ContextMenuActionDelegate?) -> Action {
            return Action(
                icon: UIImage(named: "ic_reply"),
                title: "reply".localized(),
                accessibilityLabel: "Reply to message"
            ) { delegate?.reply(cellViewModel) }
        }

        static func copy(_ cellViewModel: MessageViewModel, _ delegate: ContextMenuActionDelegate?) -> Action {
            return Action(
                icon: UIImage(named: "ic_copy"),
                title: "copy".localized(),
                accessibilityLabel: "Copy text"
            ) { delegate?.copy(cellViewModel) }
        }

        static func copySessionID(_ cellViewModel: MessageViewModel, _ delegate: ContextMenuActionDelegate?) -> Action {
            return Action(
                icon: UIImage(named: "ic_copy"),
                title: "accountIDCopy".localized(),
                accessibilityLabel: "Copy Session ID"
            ) { delegate?.copySessionID(cellViewModel) }
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
                accessibilityLabel: "Delete message"
            ) { delegate?.delete(cellViewModel) }
        }

        static func save(_ cellViewModel: MessageViewModel, _ delegate: ContextMenuActionDelegate?) -> Action {
            return Action(
                icon: UIImage(named: "ic_download"),
                title: "save".localized(),
                accessibilityLabel: "Save attachment"
            ) { delegate?.save(cellViewModel) }
        }

        static func ban(_ cellViewModel: MessageViewModel, _ delegate: ContextMenuActionDelegate?) -> Action {
            return Action(
                icon: UIImage(named: "ic_block"),
                title: "banUser".localized(),
                themeColor: .danger,
                accessibilityLabel: "Ban user"
            ) { delegate?.ban(cellViewModel) }
        }
        
        static func banAndDeleteAllMessages(_ cellViewModel: MessageViewModel, _ delegate: ContextMenuActionDelegate?) -> Action {
            return Action(
                icon: UIImage(named: "ic_block"),
                title: "banDeleteAll".localized(),
                themeColor: .danger,
                accessibilityLabel: "Ban user and delete"
            ) { delegate?.banAndDeleteAllMessages(cellViewModel) }
        }
        
        static func react(_ cellViewModel: MessageViewModel, _ emoji: EmojiWithSkinTones, _ delegate: ContextMenuActionDelegate?) -> Action {
            return Action(
                title: emoji.rawValue,
                actionType: .emoji
            ) { delegate?.react(cellViewModel, with: emoji) }
        }
        
        static func emojiPlusButton(_ cellViewModel: MessageViewModel, _ delegate: ContextMenuActionDelegate?) -> Action {
            return Action(
                actionType: .emojiPlus,
                accessibilityLabel: "Add emoji"
            ) { delegate?.showFullEmojiKeyboard(cellViewModel) }
        }
        
        static func dismiss(_ delegate: ContextMenuActionDelegate?) -> Action {
            return Action(
                actionType: .dismiss
            ) { delegate?.contextMenuDismissed() }
        }
    }
    
    static func viewModelCanReply(_ cellViewModel: MessageViewModel, using dependencies: Dependencies) -> Bool {
        return (
            (
                cellViewModel.threadVariant != .legacyGroup ||
                !dependencies[feature: .legacyGroupsDeprecated]
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
        
        let canRetry: Bool = (
            (
                cellViewModel.threadVariant != .legacyGroup ||
                !dependencies[feature: .legacyGroupsDeprecated]
            ) &&
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
        let canSave: Bool = (
            cellViewModel.cellType == .mediaMessage &&
            (cellViewModel.attachments ?? [])
                .filter { attachment in
                    attachment.isValid &&
                    attachment.isVisualMedia && (
                        attachment.state == .downloaded ||
                        attachment.state == .uploaded
                    )
                }.isEmpty == false
        )
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
                on: threadViewModel.openGroupServer
            )
        )
        let shouldShowEmojiActions: Bool = {
            guard
                cellViewModel.threadVariant != .legacyGroup ||
                !dependencies[feature: .legacyGroupsDeprecated]
            else { return false }
            
            if cellViewModel.threadVariant == .community {
                return dependencies[singleton: .openGroupManager].doesOpenGroupSupport(
                    capability: .reactions,
                    on: cellViewModel.threadOpenGroupServer
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
}

// MARK: - Delegate

protocol ContextMenuActionDelegate {
    func info(_ cellViewModel: MessageViewModel)
    func retry(_ cellViewModel: MessageViewModel)
    func reply(_ cellViewModel: MessageViewModel)
    func copy(_ cellViewModel: MessageViewModel)
    func copySessionID(_ cellViewModel: MessageViewModel)
    func delete(_ cellViewModel: MessageViewModel)
    func save(_ cellViewModel: MessageViewModel)
    func ban(_ cellViewModel: MessageViewModel)
    func banAndDeleteAllMessages(_ cellViewModel: MessageViewModel)
    func react(_ cellViewModel: MessageViewModel, with emoji: EmojiWithSkinTones)
    func showFullEmojiKeyboard(_ cellViewModel: MessageViewModel)
    func contextMenuDismissed()
}
