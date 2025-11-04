// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Lucide
import GRDB
import SessionMessagingKit
import SessionUIKit
import SessionUtilitiesKit

protocol SwipeActionOptimisticCell {
    func optimisticUpdate(isMuted: Bool?, isPinned: Bool?, hasUnread: Bool?)
}

extension SwipeActionOptimisticCell {
    public func optimisticUpdate(isMuted: Bool) {
        optimisticUpdate(isMuted: isMuted, isPinned: nil, hasUnread: nil)
    }
    
    public func optimisticUpdate(isPinned: Bool) {
        optimisticUpdate(isMuted: nil, isPinned: isPinned, hasUnread: nil)
    }
    
    public func optimisticUpdate(hasUnread: Bool) {
        optimisticUpdate(isMuted: nil, isPinned: nil, hasUnread: hasUnread)
    }
}

public extension UIContextualAction {
    enum SwipeAction {
        case toggleReadStatus
        case hide
        case pin
        case mute
        case block
        case leave
        case delete
        case deleteContact
        case clear
    }
    
    static func configuration(for actions: [UIContextualAction]?) -> UISwipeActionsConfiguration? {
        return actions.map { UISwipeActionsConfiguration(actions: $0) }
    }
    
    static func generateSwipeActions(
        _ actions: [SwipeAction],
        for side: UIContextualAction.Side,
        indexPath: IndexPath,
        tableView: UITableView,
        threadViewModel: SessionThreadViewModel,
        viewController: UIViewController?,
        navigatableStateHolder: NavigatableStateHolder?,
        using dependencies: Dependencies
    ) -> [UIContextualAction]? {
        guard !actions.isEmpty else { return nil }
        
        let unswipeAnimationDelay: DispatchTimeInterval = .milliseconds(500)
        
        // Note: for some reason the `UISwipeActionsConfiguration` expects actions to be left-to-right
        // for leading actions, but right-to-left for trailing actions...
        let targetActions: [SwipeAction] = (side == .trailing ? actions.reversed() : actions)
        let actionBackgroundColor: [ThemeValue] = [
            .conversationButton_swipeDestructive,
            .conversationButton_swipeSecondary,
            .conversationButton_swipeTertiary
        ]
        
        return targetActions
            .enumerated()
            .compactMap { index, action -> UIContextualAction? in
                // Even though we have to reverse the actions above, the indexes in the view hierarchy
                // are in the expected order
                let targetIndex: Int = (side == .trailing ? (targetActions.count - index) : index)
                let themeBackgroundColor: ThemeValue = actionBackgroundColor[
                    index % actionBackgroundColor.count
                ]
                
                switch action {
                    // MARK: -- toggleReadStatus
                        
                    case .toggleReadStatus:
                        let isUnread: Bool = (
                            threadViewModel.threadWasMarkedUnread == true ||
                            (threadViewModel.threadUnreadCount ?? 0) > 0
                        )
                        
                        return UIContextualAction(
                            title: (isUnread ?
                                "messageMarkRead".localized() :
                                "messageMarkUnread".localized()
                            ),
                            icon: (isUnread ?
                                UIImage(systemName: "envelope.open") :
                                UIImage(systemName: "envelope.badge")
                            ),
                            themeTintColor: .white,
                            themeBackgroundColor: .conversationButton_swipeRead,    // Always Custom
                            accessibility: Accessibility(identifier: (isUnread ? "Mark Read button" : "Mark Unread button")),
                            side: side,
                            actionIndex: targetIndex,
                            indexPath: indexPath,
                            tableView: tableView
                        ) { _, _, completionHandler  in
                            // Delay the change to give the cell "unswipe" animation some time to complete
                            DispatchQueue.global(qos: .default).asyncAfter(deadline: .now() + unswipeAnimationDelay) {
                                switch isUnread {
                                    case true: threadViewModel.markAsRead(
                                        target: .threadAndInteractions(
                                            interactionsBeforeInclusive: threadViewModel.interactionId
                                        ),
                                        using: dependencies
                                    )
                                        
                                    case false: threadViewModel.markAsUnread(using: dependencies)
                                }
                            }
                            completionHandler(true)
                        }
                    
                    // MARK: -- clear
                    
                    case .clear:
                        return UIContextualAction(
                            title: "clear".localized(),
                            icon: Lucide.image(icon: .trash2, size: 24),
                            themeTintColor: .white,
                            themeBackgroundColor: themeBackgroundColor,
                            side: side,
                            actionIndex: targetIndex,
                            indexPath: indexPath,
                            tableView: tableView
                        ) { _, _, completionHandler  in
                            let confirmationModal: ConfirmationModal = ConfirmationModal(
                                info: ConfirmationModal.Info(
                                    title: "clearMessages".localized(),
                                    body: .text("clearMessagesNoteToSelfDescription".localized()),
                                    confirmTitle: "clear".localized(),
                                    confirmStyle: .danger,
                                    cancelStyle: .alert_text,
                                    dismissOnConfirm: true,
                                    onConfirm: { _ in
                                        dependencies[singleton: .storage].writeAsync { db in
                                            try SessionThread.deleteOrLeave(
                                                db,
                                                type: .deleteContactConversationAndMarkHidden,
                                                threadId: threadViewModel.threadId,
                                                threadVariant: threadViewModel.threadVariant,
                                                using: dependencies
                                            )
                                        }
                                        
                                        completionHandler(true)
                                    },
                                    afterClosed: { completionHandler(false) }
                                )
                            )
                            
                            viewController?.present(confirmationModal, animated: true, completion: nil)
                        }
                        
                    // MARK: -- hide
                        
                    case .hide:
                        return UIContextualAction(
                            title: "hide".localized(),
                            icon: UIImage(systemName: "eye.slash"),
                            themeTintColor: .white,
                            themeBackgroundColor: themeBackgroundColor,
                            accessibility: Accessibility(identifier: "Hide button"),
                            side: side,
                            actionIndex: targetIndex,
                            indexPath: indexPath,
                            tableView: tableView
                        ) { _, _, completionHandler  in
                            switch threadViewModel.threadId {
                                case SessionThreadViewModel.messageRequestsSectionId:
                                    dependencies.setAsync(.hasHiddenMessageRequests, true)
                                    completionHandler(true)
                                    
                                default:
                                    let confirmationModal: ConfirmationModal = ConfirmationModal(
                                        info: ConfirmationModal.Info(
                                            title: "noteToSelfHide".localized(),
                                            body: .attributedText(
                                                "hideNoteToSelfDescription"
                                                    .localizedFormatted(baseFont: ConfirmationModal.explanationFont)
                                            ),
                                            confirmTitle: "hide".localized(),
                                            confirmStyle: .danger,
                                            cancelStyle: .alert_text,
                                            dismissOnConfirm: true,
                                            onConfirm: { _ in
                                                dependencies[singleton: .storage].writeAsync { db in
                                                    try SessionThread.deleteOrLeave(
                                                        db,
                                                        type: .hideContactConversation,
                                                        threadId: threadViewModel.threadId,
                                                        threadVariant: threadViewModel.threadVariant,
                                                        using: dependencies
                                                    )
                                                }
                                                
                                                completionHandler(true)
                                            },
                                            afterClosed: { completionHandler(false) }
                                        )
                                    )
                                    
                                    viewController?.present(confirmationModal, animated: true, completion: nil)
                            }
                        }
                        
                    // MARK: -- pin
                        
                    case .pin:
                        let isCurrentlyPinned: Bool = (threadViewModel.threadPinnedPriority > 0)
                        return UIContextualAction(
                            title: (isCurrentlyPinned ? "pinUnpin".localized() : "pin".localized()),
                            icon: (isCurrentlyPinned ? UIImage(systemName: "pin.slash") : UIImage(systemName: "pin")),
                            themeTintColor: .white,
                            themeBackgroundColor: .conversationButton_swipeTertiary,    // Always Tertiary
                            accessibility: Accessibility(
                                identifier: (isCurrentlyPinned ? "Pin button" : "Unpin button")
                            ),
                            side: side,
                            actionIndex: targetIndex,
                            indexPath: indexPath,
                            tableView: tableView
                        ) { _, _, completionHandler in
                            if !isCurrentlyPinned,
                               !dependencies[cache: .libSession].isSessionPro,
                               let pinnedConversationsNumber: Int = dependencies[singleton: .storage].read({ db in
                                   try SessionThread
                                       .filter(SessionThread.Columns.pinnedPriority > 0)
                                       .fetchCount(db)
                               }),
                               pinnedConversationsNumber >= LibSession.PinnedConversationLimit
                            {
                                let sessionProModal: ModalHostingViewController = ModalHostingViewController(
                                    modal: ProCTAModal(
                                        variant: .morePinnedConvos(
                                            isGrandfathered: (pinnedConversationsNumber > LibSession.PinnedConversationLimit)
                                        ),
                                        dataManager: dependencies[singleton: .imageDataManager],
                                        afterClosed: { [completionHandler] in
                                            completionHandler(true)
                                        },
                                        onConfirm: { [dependencies] in
                                            dependencies[singleton: .sessionProState].upgradeToPro(
                                                plan: SessionProPlan(variant: .threeMonths),
                                                originatingPlatform: .iOS,
                                                completion: nil
                                            )
                                        }
                                    )
                                )
                                viewController?.present(sessionProModal, animated: true, completion: nil)
                                return
                            }
                            
                            (tableView.cellForRow(at: indexPath) as? SwipeActionOptimisticCell)?
                                .optimisticUpdate(isPinned: !isCurrentlyPinned)
                            completionHandler(true)
                            
                            // Delay the change to give the cell "unswipe" animation some time to complete
                            DispatchQueue.global(qos: .default).asyncAfter(deadline: .now() + unswipeAnimationDelay) {
                                dependencies[singleton: .storage].writeAsync { db in
                                    try SessionThread
                                        .filter(id: threadViewModel.threadId)
                                        .updateAllAndConfig(
                                            db,
                                            SessionThread.Columns.pinnedPriority
                                                .set(to: (isCurrentlyPinned ? 0 : 1)),
                                            using: dependencies
                                        )
                                }
                            }
                        }

                    // MARK: -- mute

                    case .mute:
                        return UIContextualAction(
                            title: (threadViewModel.threadMutedUntilTimestamp == nil ?
                                "notificationsMute".localized() :
                                "notificationsMuteUnmute".localized()
                            ),
                            icon: (threadViewModel.threadMutedUntilTimestamp == nil ?
                                UIImage(systemName: "speaker.slash") :
                                UIImage(systemName: "speaker")
                            ),
                            themeTintColor: .white,
                            themeBackgroundColor: themeBackgroundColor,
                            accessibility: Accessibility(
                                identifier: (threadViewModel.threadMutedUntilTimestamp == nil ? "Mute button" : "Unmute button")
                            ),
                            side: side,
                            actionIndex: targetIndex,
                            indexPath: indexPath,
                            tableView: tableView
                        ) { _, _, completionHandler in
                            (tableView.cellForRow(at: indexPath) as? SwipeActionOptimisticCell)?
                                .optimisticUpdate(
                                    isMuted: !(threadViewModel.threadMutedUntilTimestamp != nil)
                                )
                            completionHandler(true)
                            
                            // Delay the change to give the cell "unswipe" animation some time to complete
                            DispatchQueue.global(qos: .default).asyncAfter(deadline: .now() + unswipeAnimationDelay) {
                                dependencies[singleton: .storage].writeAsync { db in
                                    let currentValue: TimeInterval? = try SessionThread
                                        .filter(id: threadViewModel.threadId)
                                        .select(.mutedUntilTimestamp)
                                        .asRequest(of: TimeInterval.self)
                                        .fetchOne(db)
                                    let newValue: TimeInterval? = (currentValue == nil ?
                                        Date.distantFuture.timeIntervalSince1970 :
                                        nil
                                    )
                                    
                                    try SessionThread
                                        .filter(id: threadViewModel.threadId)
                                        .updateAll(
                                            db,
                                            SessionThread.Columns.mutedUntilTimestamp.set(to: newValue)
                                        )
                                    
                                    if currentValue != newValue {
                                        db.addConversationEvent(
                                            id: threadViewModel.threadId,
                                            type: .updated(.mutedUntilTimestamp(newValue))
                                        )
                                    }
                                }
                            }
                        }
                        
                    // MARK: -- block
                        
                    case .block:
                        /// If we don't have the `profileInfo` then we can't actually block so don't offer the block option in that case
                        guard
                            let profileInfo: (id: String, profile: Profile?) = dependencies[singleton: .storage]
                                .read({ db in
                                switch threadViewModel.threadVariant {
                                    case .contact:
                                        return (
                                            threadViewModel.threadId,
                                            try Profile.fetchOne(db, id: threadViewModel.threadId)
                                        )
                                        
                                    case .group:
                                        let firstAdmin: GroupMember? = try GroupMember
                                            .filter(GroupMember.Columns.groupId == threadViewModel.threadId)
                                            .filter(GroupMember.Columns.role == GroupMember.Role.admin)
                                            .fetchOne(db)
                                        
                                        return try firstAdmin
                                            .map { admin in
                                                (
                                                    admin.profileId,
                                                    try Profile.fetchOne(db, id: admin.profileId)
                                                )
                                            }
                                        
                                    default: return nil
                                }
                            })
                        else { return nil }
                        
                        return UIContextualAction(
                            title: (threadViewModel.threadIsBlocked == true ?
                                "blockUnblock".localized() :
                                "block".localized()
                            ),
                            icon: UIImage(named: "ic_user_round_ban")?.withRenderingMode(.alwaysTemplate),
                            themeTintColor: .white,
                            themeBackgroundColor: themeBackgroundColor,
                            accessibility: Accessibility(identifier: "Block button"),
                            side: side,
                            actionIndex: targetIndex,
                            indexPath: indexPath,
                            tableView: tableView
                        ) { [weak viewController] _, _, completionHandler in
                            let threadIsBlocked: Bool = (threadViewModel.threadIsBlocked == true)
                            let threadIsContactMessageRequest: Bool = (
                                threadViewModel.threadVariant == .contact &&
                                threadViewModel.threadIsMessageRequest == true
                            )
                            let contactChanges: [ConfigColumnAssignment] = [
                                Contact.Columns.isBlocked.set(to: !threadIsBlocked),
                                
                                /// **Note:** We set `didApproveMe` to `true` so the current user will be able to send a
                                /// message to the person who originally sent them the message request in the future if they
                                /// unblock them
                                (!threadIsContactMessageRequest ? nil : Contact.Columns.didApproveMe.set(to: true)),
                                (!threadIsContactMessageRequest ? nil : Contact.Columns.isApproved.set(to: false))
                            ].compactMap { $0 }
                            let contactChangeEvents: [ContactEvent.Change] = (!threadIsContactMessageRequest ? [] :
                                [.isApproved(false), .didApproveMe(true)]
                            )
                            let nameToUse: String = {
                                switch threadViewModel.threadVariant {
                                    case .group:
                                        return Profile.displayName(
                                            for: .contact,
                                            id: profileInfo.id,
                                            name: profileInfo.profile?.name,
                                            nickname: profileInfo.profile?.nickname,
                                            suppressId: false
                                        )
                                        
                                    default: return threadViewModel.displayName
                                }
                            }()
                            
                            let confirmationModal: ConfirmationModal = ConfirmationModal(
                                info: ConfirmationModal.Info(
                                    title: (threadIsBlocked ?
                                        "blockUnblock".localized() :
                                        "block".localized()
                                    ),
                                    body: (threadIsBlocked ?
                                        .attributedText(
                                            "blockUnblockName"
                                                .put(key: "name", value: nameToUse)
                                                .localizedFormatted(baseFont: ConfirmationModal.explanationFont)
                                        ) :
                                        .attributedText(
                                            "blockDescription"
                                                .put(key: "name", value: nameToUse)
                                                .localizedFormatted(baseFont: ConfirmationModal.explanationFont)
                                        )
                                    ),
                                    confirmTitle: (threadIsBlocked ?
                                        "blockUnblock".localized() :
                                        "block".localized()
                                    ),
                                    confirmStyle: .danger,
                                    cancelStyle: .alert_text,
                                    dismissOnConfirm: true,
                                    onConfirm: { _ in
                                        completionHandler(true)
                                        
                                        // Delay the change to give the cell "unswipe" animation some time to complete
                                        DispatchQueue.global(qos: .default).asyncAfter(deadline: .now() + unswipeAnimationDelay) {
                                            dependencies[singleton: .storage]
                                                .writePublisher { db in
                                                    // Create the contact if it doesn't exist
                                                    switch threadViewModel.threadVariant {
                                                        case .contact:
                                                            try Contact
                                                                .fetchOrCreate(
                                                                    db,
                                                                    id: threadViewModel.threadId,
                                                                    using: dependencies
                                                                )
                                                                .upsert(db)
                                                            try Contact
                                                                .filter(id: threadViewModel.threadId)
                                                                .updateAllAndConfig(
                                                                    db,
                                                                    contactChanges,
                                                                    using: dependencies
                                                                )
                                                            contactChangeEvents.forEach { change in
                                                                db.addContactEvent(
                                                                    id: threadViewModel.threadId,
                                                                    change: change
                                                                )
                                                            }
                                                            
                                                        case .group:
                                                            try Contact
                                                                .fetchOrCreate(
                                                                    db,
                                                                    id: profileInfo.id,
                                                                    using: dependencies
                                                                )
                                                                .upsert(db)
                                                            try Contact
                                                                .filter(id: profileInfo.id)
                                                                .updateAllAndConfig(
                                                                    db,
                                                                    contactChanges,
                                                                    using: dependencies
                                                                )
                                                            contactChangeEvents.forEach { change in
                                                                db.addContactEvent(
                                                                    id: profileInfo.id,
                                                                    change: change
                                                                )
                                                            }
                                                            
                                                        default: break
                                                    }
                                                    
                                                    // Blocked message requests should be deleted
                                                    if threadViewModel.threadIsMessageRequest == true {
                                                        try SessionThread.deleteOrLeave(
                                                            db,
                                                            type: .deleteContactConversationAndMarkHidden,
                                                            threadId: threadViewModel.threadId,
                                                            threadVariant: threadViewModel.threadVariant,
                                                            using: dependencies
                                                        )
                                                    }
                                                }
                                                .subscribe(on: DispatchQueue.global(qos: .userInitiated))
                                                .sinkUntilComplete()
                                        }
                                    },
                                    afterClosed: { completionHandler(false) }
                                )
                            )
                            
                            viewController?.present(confirmationModal, animated: true, completion: nil)
                        }

                    // MARK: -- leave

                    case .leave:
                        return UIContextualAction(
                            title: "leave".localized(),
                            icon: UIImage(systemName: "rectangle.portrait.and.arrow.right"),
                            themeTintColor: .white,
                            themeBackgroundColor: themeBackgroundColor,
                            accessibility: Accessibility(identifier: "Leave button"),
                            side: side,
                            actionIndex: targetIndex,
                            indexPath: indexPath,
                            tableView: tableView
                        ) { [weak viewController] _, _, completionHandler in
                            let confirmationModalTitle: String = {
                                switch threadViewModel.threadVariant {
                                    case .legacyGroup, .group:
                                        return "groupLeave".localized()
                                        
                                    default: return "communityLeave".localized()
                                }
                            }()
                            
                            let confirmationModalExplanation: ThemedAttributedString = {
                                switch (threadViewModel.threadVariant, threadViewModel.currentUserIsClosedGroupAdmin) {
                                    case (.group, true):
                                        return "groupLeaveDescriptionAdmin"
                                            .put(key: "group_name", value: threadViewModel.displayName)
                                            .localizedFormatted(baseFont: ConfirmationModal.explanationFont)
                                    
                                    case (.legacyGroup, true):
                                        return "groupLeaveDescription"
                                            .put(key: "group_name", value: threadViewModel.displayName)
                                            .localizedFormatted(baseFont: ConfirmationModal.explanationFont)
                                    
                                    default:
                                        return "groupLeaveDescription"
                                            .put(key: "group_name", value: threadViewModel.displayName)
                                            .localizedFormatted(baseFont: ConfirmationModal.explanationFont)
                                }
                            }()
                            
                            let confirmationModal: ConfirmationModal = ConfirmationModal(
                                info: ConfirmationModal.Info(
                                    title: confirmationModalTitle,
                                    body: .attributedText(confirmationModalExplanation),
                                    confirmTitle: "leave".localized(),
                                    confirmStyle: .danger,
                                    cancelStyle: .alert_text,
                                    dismissOnConfirm: true,
                                    onConfirm: { _ in
                                        let deletionType: SessionThread.DeletionType = {
                                            switch threadViewModel.threadVariant {
                                                case .legacyGroup, .group: return .leaveGroupAsync
                                                default: return .deleteCommunityAndContent
                                            }
                                        }()
                                        
                                        dependencies[singleton: .storage].writeAsync { db in
                                            do {
                                                try SessionThread.deleteOrLeave(
                                                    db,
                                                    type: deletionType,
                                                    threadId: threadViewModel.threadId,
                                                    threadVariant: threadViewModel.threadVariant,
                                                    using: dependencies
                                                )
                                            } catch {
                                                DispatchQueue.main.async {
                                                    let toastBody: String = {
                                                        switch threadViewModel.threadVariant {
                                                            case .legacyGroup, .group:
                                                                return "groupLeaveErrorFailed"
                                                                    .put(key: "group_name", value: threadViewModel.displayName)
                                                                    .localized()
                                                                
                                                            default:
                                                                return "communityLeaveError"
                                                                    .put(key: "community_name", value: threadViewModel.displayName)
                                                                    .localized()
                                                        }
                                                    }()
                                                    navigatableStateHolder?.showToast(
                                                        text: toastBody,
                                                        backgroundColor: .backgroundSecondary
                                                    )
                                                }
                                            }
                                        }
                                        
                                        completionHandler(true)
                                    },
                                    afterClosed: { completionHandler(false) }
                                )
                            )
                            
                            viewController?.present(confirmationModal, animated: true, completion: nil)
                        }
                        
                    // MARK: -- delete
                        
                    case .delete:
                        return UIContextualAction(
                            title: "delete".localized(),
                            icon: Lucide.image(icon: .trash2, size: 24),
                            themeTintColor: .white,
                            themeBackgroundColor: themeBackgroundColor,
                            accessibility: Accessibility(identifier: "Delete button"),
                            side: side,
                            actionIndex: targetIndex,
                            indexPath: indexPath,
                            tableView: tableView
                        ) { [weak viewController] _, _, completionHandler in
                            let isMessageRequest: Bool = (threadViewModel.threadIsMessageRequest == true)
                            let groupDestroyedOrKicked: Bool = {
                                guard threadViewModel.threadVariant == .group else { return false }
                                
                                return (
                                    threadViewModel.wasKickedFromGroup == true ||
                                    threadViewModel.groupIsDestroyed == true
                                )
                            }()
                            let confirmationModalTitle: String = {
                                switch (threadViewModel.threadVariant, isMessageRequest) {
                                    case (_, true): return "delete".localized()
                                    case (.contact, _):
                                        return "conversationsDelete".localized()
                                        
                                    case (.legacyGroup, _), (.group, _):
                                        return "groupDelete".localized()
                                        
                                    case (.community, _): return "delete".localized()
                                }
                            }()
                            let confirmationModalExplanation: ThemedAttributedString = {
                                guard !isMessageRequest else {
                                    switch threadViewModel.threadVariant {
                                        case .group: return ThemedAttributedString(string: "groupInviteDelete".localized())
                                        default: return ThemedAttributedString(string: "messageRequestsContactDelete".localized())
                                    }
                                }
                                
                                let threadInfo: (SessionThread.Variant, Bool) = (
                                    threadViewModel.threadVariant,
                                    threadViewModel.currentUserIsClosedGroupAdmin == true
                                )
                                
                                switch threadInfo {
                                    case (.contact, _):
                                        return "deleteConversationDescription"
                                            .put(key: "name", value: threadViewModel.displayName)
                                            .localizedFormatted(baseFont: ConfirmationModal.explanationFont)
                                        
                                    case (.group, true):
                                        return "groupDeleteDescription"
                                            .put(key: "group_name", value: threadViewModel.displayName)
                                            .localizedFormatted(baseFont: ConfirmationModal.explanationFont)
                                    
                                    default:
                                        return "groupDeleteDescriptionMember"
                                            .put(key: "group_name", value: threadViewModel.displayName)
                                            .localizedFormatted(baseFont: ConfirmationModal.explanationFont)
                                }
                            }()
                            
                            let confirmationModal: ConfirmationModal = ConfirmationModal(
                                info: ConfirmationModal.Info(
                                    title: confirmationModalTitle,
                                    body: .attributedText(confirmationModalExplanation),
                                    confirmTitle: "delete".localized(),
                                    confirmStyle: .danger,
                                    cancelStyle: .alert_text,
                                    dismissOnConfirm: true,
                                    onConfirm: { _ in
                                        let deletionType: SessionThread.DeletionType = {
                                            switch (threadViewModel.threadVariant, isMessageRequest, groupDestroyedOrKicked) {
                                                case (.community, _, _): return .deleteCommunityAndContent
                                                case (.group, true, _), (.group, _, true), (.legacyGroup, _, _):
                                                    return .deleteGroupAndContent
                                                case (.group, _, _): return .leaveGroupAsync
                                                
                                                case (.contact, true, _):
                                                    return .deleteContactConversationAndContact
                                                    
                                                case (.contact, false, _):
                                                    return .deleteContactConversationAndMarkHidden
                                            }
                                        }()
                                        
                                        dependencies[singleton: .storage].writeAsync { db in
                                            try SessionThread.deleteOrLeave(
                                                db,
                                                type: deletionType,
                                                threadId: threadViewModel.threadId,
                                                threadVariant: threadViewModel.threadVariant,
                                                using: dependencies
                                            )
                                        }
                                        
                                        completionHandler(true)
                                    },
                                    afterClosed: { completionHandler(false) }
                                )
                            )
                            
                            viewController?.present(confirmationModal, animated: true, completion: nil)
                        }
                    
                    // MARK: -- deleteContact
                        
                    case .deleteContact:
                        return UIContextualAction(
                            title: "contactDelete".localized(),
                            icon: UIImage(named: "ic_user_round_trash")?
                                .withRenderingMode(.alwaysTemplate),
                            themeTintColor: .white,
                            themeBackgroundColor: themeBackgroundColor,
                            accessibility: Accessibility(identifier: "Delete button"),
                            side: side,
                            actionIndex: targetIndex,
                            indexPath: indexPath,
                            tableView: tableView
                        ) { [weak viewController] _, _, completionHandler in
                            let confirmationModal: ConfirmationModal = ConfirmationModal(
                                info: ConfirmationModal.Info(
                                    title: "contactDelete".localized(),
                                    body: .attributedText(
                                        "contactDeleteDescription"
                                            .put(key: "name", value: threadViewModel.displayName)
                                            .localizedFormatted(baseFont: ConfirmationModal.explanationFont)
                                    ),
                                    confirmTitle: "delete".localized(),
                                    confirmStyle: .danger,
                                    cancelStyle: .alert_text,
                                    dismissOnConfirm: true,
                                    onConfirm: { _ in
                                        dependencies[singleton: .storage].writeAsync { db in
                                            try SessionThread.deleteOrLeave(
                                                db,
                                                type: .deleteContactConversationAndContact,
                                                threadId: threadViewModel.threadId,
                                                threadVariant: threadViewModel.threadVariant,
                                                using: dependencies
                                            )
                                        }
                                        
                                        completionHandler(true)
                                    },
                                    afterClosed: { completionHandler(false) }
                                )
                            )
                            
                            viewController?.present(confirmationModal, animated: true, completion: nil)
                        }
                }
            }
    }
}
