// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import YYImage
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SignalUtilitiesKit
import SessionUtilitiesKit
import SessionSnodeKit

class ThreadSettingsViewModel: SessionTableViewModel<ThreadSettingsViewModel.NavButton, ThreadSettingsViewModel.Section, ThreadSettingsViewModel.Setting> {
    // MARK: - Config
    
    enum NavState {
        case standard
        case editing
    }
    
    enum NavButton: Equatable {
        case edit
        case cancel
        case done
    }
    
    public enum Section: SessionTableSection {
        case conversationInfo
        case content
    }
    
    public enum Setting: Differentiable {
        case avatar
        case nickname
        case sessionId
        
        case copyThreadId
        case allMedia
        case searchConversation
        case addToOpenGroup
        case disappearingMessages
        case disappearingMessagesDuration
        case editGroup
        case leaveGroup
        case notificationSound
        case notificationMentionsOnly
        case notificationMute
        case blockUser
    }
    
    // MARK: - Variables
    
    private let dependencies: Dependencies
    private let threadId: String
    private let threadVariant: SessionThread.Variant
    private let didTriggerSearch: () -> ()
    private var oldDisplayName: String?
    private var editedDisplayName: String?
    
    // MARK: - Initialization
    
    init(
        threadId: String,
        threadVariant: SessionThread.Variant,
        didTriggerSearch: @escaping () -> (),
        using dependencies: Dependencies = Dependencies()
    ) {
        self.dependencies = dependencies
        self.threadId = threadId
        self.threadVariant = threadVariant
        self.didTriggerSearch = didTriggerSearch
        self.oldDisplayName = (threadVariant != .contact ?
            nil :
            dependencies.storage.read { db in
                try Profile
                    .filter(id: threadId)
                    .select(.nickname)
                    .asRequest(of: String.self)
                    .fetchOne(db)
            }
       )
    }
    
    // MARK: - Navigation
    
    lazy var navState: AnyPublisher<NavState, Never> = {
        Publishers
            .CombineLatest(
                isEditing,
                textChanged
                    .handleEvents(
                        receiveOutput: { [weak self] value, _ in
                            self?.editedDisplayName = value
                        }
                    )
                    .filter { _ in false }
                    .prepend((nil, .nickname))
            )
            .map { isEditing, _ -> NavState in (isEditing ? .editing : .standard) }
            .removeDuplicates()
            .prepend(.standard)     // Initial value
            .shareReplay(1)
            .eraseToAnyPublisher()
    }()

    override var leftNavItems: AnyPublisher<[NavItem]?, Never> {
       navState
           .map { [weak self] navState -> [NavItem] in
               // Only show the 'Edit' button if it's a contact thread
               guard self?.threadVariant == .contact else { return [] }
               guard navState == .editing else { return [] }

               return [
                   NavItem(
                       id: .cancel,
                       systemItem: .cancel,
                       accessibilityIdentifier: "Cancel button"
                   ) { [weak self] in
                       self?.setIsEditing(false)
                       self?.editedDisplayName = self?.oldDisplayName
                   }
               ]
           }
           .eraseToAnyPublisher()
    }

    override var rightNavItems: AnyPublisher<[NavItem]?, Never> {
       navState
           .map { [weak self, dependencies] navState -> [NavItem] in
               // Only show the 'Edit' button if it's a contact thread
               guard self?.threadVariant == .contact else { return [] }

               switch navState {
                   case .editing:
                       return [
                           NavItem(
                               id: .done,
                               systemItem: .done,
                               accessibilityIdentifier: "Done"
                           ) { [weak self] in
                               self?.setIsEditing(false)
                               
                               guard
                                   self?.threadVariant == .contact,
                                   let threadId: String = self?.threadId,
                                   let editedDisplayName: String = self?.editedDisplayName
                               else { return }
                               
                               let updatedNickname: String = editedDisplayName
                                   .trimmingCharacters(in: .whitespacesAndNewlines)
                               self?.oldDisplayName = (updatedNickname.isEmpty ? nil : editedDisplayName)

                               dependencies.storage.writeAsync { db in
                                   try Profile
                                       .filter(id: threadId)
                                       .updateAllAndConfig(
                                           db,
                                           Profile.Columns.nickname
                                               .set(to: (updatedNickname.isEmpty ? nil : editedDisplayName))
                                       )
                               }
                           }
                       ]

                   case .standard:
                       return [
                           NavItem(
                               id: .edit,
                               systemItem: .edit,
                               accessibilityIdentifier: "Edit button",
                               accessibilityLabel: "Edit user nickname"
                           ) { [weak self] in self?.setIsEditing(true) }
                       ]
               }
           }
           .eraseToAnyPublisher()
    }
    
    // MARK: - Content
    
    private var originalState: SessionThreadViewModel?
    override var title: String {
        switch threadVariant {
            case .contact: return "vc_settings_title".localized()
            case .legacyGroup, .group, .community: return "vc_group_settings_title".localized()
        }
    }
    
    public override var observableTableData: ObservableData { _observableTableData }
    
    /// This is all the data the screen needs to populate itself, please see the following link for tips to help optimise
    /// performance https://github.com/groue/GRDB.swift#valueobservation-performance
    ///
    /// **Note:** This observation will be triggered twice immediately (and be de-duped by the `removeDuplicates`)
    /// this is due to the behaviour of `ValueConcurrentObserver.asyncStartObservation` which triggers it's own
    /// fetch (after the ones in `ValueConcurrentObserver.asyncStart`/`ValueConcurrentObserver.syncStart`)
    /// just in case the database has changed between the two reads - unfortunately it doesn't look like there is a way to prevent this
    private lazy var _observableTableData: ObservableData = ValueObservation
        .trackingConstantRegion { [weak self, dependencies, threadId = self.threadId, threadVariant = self.threadVariant] db -> [SectionModel] in
            let userPublicKey: String = getUserHexEncodedPublicKey(db, using: dependencies)
            let maybeThreadViewModel: SessionThreadViewModel? = try SessionThreadViewModel
                .conversationSettingsQuery(threadId: threadId, userPublicKey: userPublicKey)
                .fetchOne(db)
            
            // If we don't get a `SessionThreadViewModel` then it means the thread was probably deleted
            // so dismiss the screen
            guard let threadViewModel: SessionThreadViewModel = maybeThreadViewModel else {
                self?.dismissScreen(type: .popToRoot)
                return []
            }
            
            // Additional Queries
            let fallbackSound: Preferences.Sound = db[.defaultNotificationSound]
                .defaulting(to: Preferences.Sound.defaultNotificationSound)
            let notificationSound: Preferences.Sound = try SessionThread
                .filter(id: threadId)
                .select(.notificationSound)
                .asRequest(of: Preferences.Sound.self)
                .fetchOne(db)
                .defaulting(to: fallbackSound)
            let disappearingMessagesConfig: DisappearingMessagesConfiguration = try DisappearingMessagesConfiguration
                .fetchOne(db, id: threadId)
                .defaulting(to: DisappearingMessagesConfiguration.defaultWith(threadId))
            let currentUserIsClosedGroupMember: Bool = (
                (
                    threadVariant == .legacyGroup ||
                    threadVariant == .group
                ) &&
                threadViewModel.currentUserIsClosedGroupMember == true
            )
            let currentUserIsClosedGroupAdmin: Bool = (
                (
                    threadVariant == .legacyGroup ||
                    threadVariant == .group
                ) &&
                threadViewModel.currentUserIsClosedGroupAdmin == true
            )
            let editIcon: UIImage? = UIImage(named: "icon_edit")
            let originalState: SessionThreadViewModel = (self?.originalState ?? threadViewModel)
            self?.originalState = threadViewModel
            
            return [
                SectionModel(
                    model: .conversationInfo,
                    elements: [
                        SessionCell.Info(
                            id: .avatar,
                            accessory: .profile(
                                id: threadViewModel.id,
                                size: .hero,
                                threadVariant: threadVariant,
                                customImageData: threadViewModel.openGroupProfilePictureData,
                                profile: threadViewModel.profile,
                                profileIcon: .none,
                                additionalProfile: threadViewModel.additionalProfile,
                                additionalProfileIcon: .none,
                                accessibility: nil
                            ),
                            styling: SessionCell.StyleInfo(
                                alignment: .centerHugging,
                                customPadding: SessionCell.Padding(bottom: Values.smallSpacing),
                                backgroundStyle: .noBackground
                            ),
                            onTap: { self?.viewProfilePicture(threadViewModel: threadViewModel) }
                        ),
                        SessionCell.Info(
                            id: .nickname,
                            leftAccessory: (threadVariant != .contact ? nil :
                                .icon(
                                    editIcon?.withRenderingMode(.alwaysTemplate),
                                    size: .fit,
                                    customTint: .textSecondary
                                )
                            ),
                            title: SessionCell.TextInfo(
                                threadViewModel.displayName,
                                font: .titleLarge,
                                alignment: .center,
                                editingPlaceholder: "CONTACT_NICKNAME_PLACEHOLDER".localized(),
                                interaction: (threadVariant == .contact ? .editable : .none)
                            ),
                            styling: SessionCell.StyleInfo(
                                alignment: .centerHugging,
                                customPadding: SessionCell.Padding(
                                    top: Values.smallSpacing,
                                    trailing: (threadVariant != .contact ?
                                        nil :
                                        -(((editIcon?.size.width ?? 0) + (Values.smallSpacing * 2)) / 2)
                                    ),
                                    bottom: (threadVariant != .contact ?
                                        nil :
                                        Values.smallSpacing
                                    ),
                                    interItem: 0
                                ),
                                backgroundStyle: .noBackground
                            ),
                            accessibility: Accessibility(
                                identifier: "Username",
                                label: threadViewModel.displayName
                            ),
                            onTap: {
                                self?.textChanged(self?.oldDisplayName, for: .nickname)
                                self?.setIsEditing(true)
                            }
                        ),

                        (threadVariant != .contact ? nil :
                            SessionCell.Info(
                                id: .sessionId,
                                subtitle: SessionCell.TextInfo(
                                    threadViewModel.id,
                                    font: .monoSmall,
                                    alignment: .center,
                                    interaction: .copy
                                ),
                                styling: SessionCell.StyleInfo(
                                    customPadding: SessionCell.Padding(
                                        top: Values.smallSpacing,
                                        bottom: Values.largeSpacing
                                    ),
                                    backgroundStyle: .noBackground
                                ),
                                accessibility: Accessibility(
                                    identifier: "Session ID",
                                    label: threadViewModel.id
                                )
                            )
                        )
                    ].compactMap { $0 }
                ),
                SectionModel(
                    model: .content,
                    elements: [
                        (threadVariant == .legacyGroup || threadVariant == .group ? nil :
                            SessionCell.Info(
                                id: .copyThreadId,
                                leftAccessory: .icon(
                                    UIImage(named: "ic_copy")?
                                        .withRenderingMode(.alwaysTemplate)
                                ),
                                title: (threadVariant == .community ?
                                    "COPY_GROUP_URL".localized() :
                                    "vc_conversation_settings_copy_session_id_button_title".localized()
                                ),
                                accessibility: Accessibility(
                                    identifier: "\(ThreadSettingsViewModel.self).copy_thread_id",
                                    label: "Copy Session ID"
                                ),
                                onTap: {
                                    switch threadVariant {
                                        case .contact, .legacyGroup, .group:
                                            UIPasteboard.general.string = threadId

                                        case .community:
                                            guard
                                                let server: String = threadViewModel.openGroupServer,
                                                let roomToken: String = threadViewModel.openGroupRoomToken,
                                                let publicKey: String = threadViewModel.openGroupPublicKey
                                            else { return }

                                            UIPasteboard.general.string = SessionUtil.communityUrlFor(
                                                server: server,
                                                roomToken: roomToken,
                                                publicKey: publicKey
                                            )
                                    }

                                    self?.showToast(
                                        text: "copied".localized(),
                                        backgroundColor: .backgroundSecondary
                                    )
                                }
                            )
                        ),

                        SessionCell.Info(
                            id: .allMedia,
                            leftAccessory: .icon(
                                UIImage(named: "actionsheet_camera_roll_black")?
                                    .withRenderingMode(.alwaysTemplate)
                            ),
                            title: MediaStrings.allMedia,
                            accessibility: Accessibility(
                                identifier: "\(ThreadSettingsViewModel.self).all_media",
                                label: "All media"
                            ),
                            onTap: { [weak self] in
                                self?.transitionToScreen(
                                    MediaGalleryViewModel.createAllMediaViewController(
                                        threadId: threadId,
                                        threadVariant: threadVariant,
                                        focusedAttachmentId: nil
                                    )
                                )
                            }
                        ),

                        SessionCell.Info(
                            id: .searchConversation,
                            leftAccessory: .icon(
                                UIImage(named: "conversation_settings_search")?
                                    .withRenderingMode(.alwaysTemplate)
                            ),
                            title: "CONVERSATION_SETTINGS_SEARCH".localized(),
                            accessibility: Accessibility(
                                identifier: "\(ThreadSettingsViewModel.self).search",
                                label: "Search"
                            ),
                            onTap: { [weak self] in
                                self?.didTriggerSearch()
                            }
                        ),

                        (threadVariant != .community ? nil :
                            SessionCell.Info(
                                id: .addToOpenGroup,
                                leftAccessory: .icon(
                                    UIImage(named: "ic_plus_24")?
                                        .withRenderingMode(.alwaysTemplate)
                                ),
                                title: "vc_conversation_settings_invite_button_title".localized(),
                                accessibility: Accessibility(
                                    identifier: "\(ThreadSettingsViewModel.self).add_to_open_group"
                                ),
                                onTap: { [weak self] in
                                    self?.transitionToScreen(
                                        UserSelectionVC(
                                            with: "vc_conversation_settings_invite_button_title".localized(),
                                            excluding: Set()
                                        ) { [weak self] selectedUsers in
                                            self?.addUsersToOpenGoup(
                                                threadViewModel: threadViewModel,
                                                selectedUsers: selectedUsers
                                            )
                                        }
                                    )
                                }
                            )
                        ),

                        (threadVariant == .community || threadViewModel.threadIsBlocked == true ? nil :
                            SessionCell.Info(
                                id: .disappearingMessages,
                                leftAccessory: .icon(
                                    UIImage(
                                        named: (disappearingMessagesConfig.isEnabled ?
                                            "ic_timer" :
                                            "ic_timer_disabled"
                                        )
                                    )?.withRenderingMode(.alwaysTemplate),
                                    accessibility: Accessibility(
                                        label: "Timer icon"
                                    )
                                ),
                                title: "DISAPPEARING_MESSAGES".localized(),
                                subtitle: (disappearingMessagesConfig.isEnabled ?
                                    String(
                                        format: "DISAPPEARING_MESSAGES_SUBTITLE_DISAPPEAR_AFTER".localized(),
                                        arguments: [disappearingMessagesConfig.durationString]
                                    ) :
                                    "DISAPPEARING_MESSAGES_SUBTITLE_OFF".localized()
                                ),
                                accessibility: Accessibility(
                                    identifier: "\(ThreadSettingsViewModel.self).disappearing_messages",
                                    label: "Disappearing messages"
                                ),
                                onTap: { [weak self] in
                                    self?.transitionToScreen(
                                        SessionTableViewController(
                                            viewModel: ThreadDisappearingMessagesSettingsViewModel(
                                                threadId: threadId,
                                                threadVariant: threadVariant,
                                                config: disappearingMessagesConfig
                                            )
                                        )
                                    )
                                }
                            )
                        ),

                        (!currentUserIsClosedGroupMember ? nil :
                            SessionCell.Info(
                                id: .editGroup,
                                leftAccessory: .icon(
                                    UIImage(named: "table_ic_group_edit")?
                                        .withRenderingMode(.alwaysTemplate)
                                ),
                                title: "EDIT_GROUP_ACTION".localized(),
                                accessibility: Accessibility(
                                    identifier: "Edit group",
                                    label: "Edit group"
                                ),
                                onTap: { [weak self] in
                                    self?.transitionToScreen(
                                        EditClosedGroupVC(threadId: threadId, threadVariant: threadVariant)
                                    )
                                }
                            )
                        ),

                        (!currentUserIsClosedGroupMember ? nil :
                            SessionCell.Info(
                                id: .leaveGroup,
                                leftAccessory: .icon(
                                    UIImage(named: "table_ic_group_leave")?
                                        .withRenderingMode(.alwaysTemplate)
                                ),
                                title: "LEAVE_GROUP_ACTION".localized(),
                                accessibility: Accessibility(
                                    identifier: "Leave group",
                                    label: "Leave group"
                                ),
                                confirmationInfo: ConfirmationModal.Info(
                                    title: "leave_group_confirmation_alert_title".localized(),
                                    body: .attributedText({
                                        if currentUserIsClosedGroupAdmin {
                                            return NSAttributedString(string: "admin_group_leave_warning".localized())
                                        }
                                        
                                        let mutableAttributedString = NSMutableAttributedString(
                                            string: String(
                                                format: "leave_community_confirmation_alert_message".localized(),
                                                threadViewModel.displayName
                                            )
                                        )
                                        mutableAttributedString.addAttribute(
                                            .font,
                                            value: UIFont.boldSystemFont(ofSize: Values.smallFontSize),
                                            range: (mutableAttributedString.string as NSString).range(of: threadViewModel.displayName)
                                        )
                                        return mutableAttributedString
                                    }()),
                                    confirmTitle: "LEAVE_BUTTON_TITLE".localized(),
                                    confirmStyle: .danger,
                                    cancelStyle: .alert_text
                                ),
                                onTap: { [weak self] in
                                    dependencies.storage.write { db in
                                        try SessionThread.deleteOrLeave(
                                            db,
                                            threadId: threadId,
                                            threadVariant: threadVariant,
                                            groupLeaveType: .standard,
                                            calledFromConfigHandling: false
                                        )
                                    }
                                }
                            )
                        ),
                         
                        (threadViewModel.threadIsNoteToSelf ? nil :
                            SessionCell.Info(
                                id: .notificationSound,
                                leftAccessory: .icon(
                                    UIImage(named: "table_ic_notification_sound")?
                                        .withRenderingMode(.alwaysTemplate)
                                ),
                                title: "SETTINGS_ITEM_NOTIFICATION_SOUND".localized(),
                                rightAccessory: .dropDown(
                                    .dynamicString { notificationSound.displayName }
                                ),
                                onTap: { [weak self] in
                                    self?.transitionToScreen(
                                        SessionTableViewController(
                                            viewModel: NotificationSoundViewModel(threadId: threadId)
                                        )
                                    )
                                }
                            )
                        ),
                        
                        (threadVariant == .contact ? nil :
                            SessionCell.Info(
                                id: .notificationMentionsOnly,
                                leftAccessory: .icon(
                                    UIImage(named: "NotifyMentions")?
                                        .withRenderingMode(.alwaysTemplate)
                                ),
                                title: "vc_conversation_settings_notify_for_mentions_only_title".localized(),
                                subtitle: "vc_conversation_settings_notify_for_mentions_only_explanation".localized(),
                                rightAccessory: .toggle(
                                    .boolValue(
                                        threadViewModel.threadOnlyNotifyForMentions == true,
                                        oldValue: (originalState.threadOnlyNotifyForMentions == true)
                                    )
                                ),
                                isEnabled: (
                                    (
                                        threadViewModel.threadVariant != .legacyGroup &&
                                        threadViewModel.threadVariant != .group
                                    ) ||
                                    currentUserIsClosedGroupMember
                                ),
                                accessibility: Accessibility(
                                    identifier: "Mentions only notification setting",
                                    label: "Mentions only"
                                ),
                                onTap: {
                                    let newValue: Bool = !(threadViewModel.threadOnlyNotifyForMentions == true)
                                    
                                    dependencies.storage.writeAsync { db in
                                        try SessionThread
                                            .filter(id: threadId)
                                            .updateAll(
                                                db,
                                                SessionThread.Columns.onlyNotifyForMentions
                                                    .set(to: newValue)
                                            )
                                    }
                                }
                            )
                        ),
                        
                        (threadViewModel.threadIsNoteToSelf ? nil :
                            SessionCell.Info(
                                id: .notificationMute,
                                leftAccessory: .icon(
                                    UIImage(named: "Mute")?
                                        .withRenderingMode(.alwaysTemplate)
                                ),
                                title: "CONVERSATION_SETTINGS_MUTE_LABEL".localized(),
                                rightAccessory: .toggle(
                                    .boolValue(
                                        threadViewModel.threadMutedUntilTimestamp != nil,
                                        oldValue: (originalState.threadMutedUntilTimestamp != nil)
                                    )
                                ),
                                isEnabled: (
                                    (
                                        threadViewModel.threadVariant != .legacyGroup &&
                                        threadViewModel.threadVariant != .group
                                    ) ||
                                    currentUserIsClosedGroupMember
                                ),
                                accessibility: Accessibility(
                                    identifier: "\(ThreadSettingsViewModel.self).mute",
                                    label: "Mute notifications"
                                ),
                                onTap: {
                                    dependencies.storage.writeAsync { db in
                                        let currentValue: TimeInterval? = try SessionThread
                                            .filter(id: threadId)
                                            .select(.mutedUntilTimestamp)
                                            .asRequest(of: TimeInterval.self)
                                            .fetchOne(db)
                                        
                                        try SessionThread
                                            .filter(id: threadId)
                                            .updateAll(
                                                db,
                                                SessionThread.Columns.mutedUntilTimestamp.set(
                                                    to: (currentValue == nil ?
                                                        Date.distantFuture.timeIntervalSince1970 :
                                                        nil
                                                    )
                                                )
                                            )
                                    }
                                }
                            )
                        ),
                        
                        (threadViewModel.threadIsNoteToSelf || threadVariant != .contact ? nil :
                            SessionCell.Info(
                                id: .blockUser,
                                leftAccessory: .icon(
                                    UIImage(named: "table_ic_block")?
                                        .withRenderingMode(.alwaysTemplate)
                                ),
                                title: "CONVERSATION_SETTINGS_BLOCK_THIS_USER".localized(),
                                rightAccessory: .toggle(
                                    .boolValue(
                                        threadViewModel.threadIsBlocked == true,
                                        oldValue: (originalState.threadIsBlocked == true)
                                    )
                                ),
                                accessibility: Accessibility(
                                    identifier: "\(ThreadSettingsViewModel.self).block",
                                    label: "Block"
                                ),
                                confirmationInfo: ConfirmationModal.Info(
                                    title: {
                                        guard threadViewModel.threadIsBlocked == true else {
                                            return String(
                                                format: "BLOCK_LIST_BLOCK_USER_TITLE_FORMAT".localized(),
                                                threadViewModel.displayName
                                            )
                                        }
                                        
                                        return String(
                                            format: "BLOCK_LIST_UNBLOCK_TITLE_FORMAT".localized(),
                                            threadViewModel.displayName
                                        )
                                    }(),
                                    body: (threadViewModel.threadIsBlocked == true ? .none :
                                        .text("BLOCK_USER_BEHAVIOR_EXPLANATION".localized())
                                    ),
                                    confirmTitle: (threadViewModel.threadIsBlocked == true ?
                                        "BLOCK_LIST_UNBLOCK_BUTTON".localized() :
                                        "BLOCK_LIST_BLOCK_BUTTON".localized()
                                    ),
                                    confirmAccessibility: Accessibility(identifier: "Confirm block"),
                                    confirmStyle: .danger,
                                    cancelStyle: .alert_text
                                ),
                                onTap: {
                                    let isBlocked: Bool = (threadViewModel.threadIsBlocked == true)
                                    
                                    self?.updateBlockedState(
                                        from: isBlocked,
                                        isBlocked: !isBlocked,
                                        threadId: threadId,
                                        displayName: threadViewModel.displayName
                                    )
                                }
                            )
                        )
                    ].compactMap { $0 }
                )
            ]
        }
        .removeDuplicates()
        .handleEvents(didFail: { SNLog("[ThreadSettingsViewModel] Observation failed with error: \($0)") })
        .publisher(in: dependencies.storage, scheduling: dependencies.scheduler)
        .mapToSessionTableViewData(for: self)
    
    // MARK: - Functions
    
    private func viewProfilePicture(threadViewModel: SessionThreadViewModel) {
        guard
            threadViewModel.threadVariant == .contact,
            let profile: Profile = threadViewModel.profile,
            let profileData: Data = ProfileManager.profileAvatar(profile: profile)
        else { return }
        
        let format: ImageFormat = profileData.guessedImageFormat
        let navController: UINavigationController = StyledNavigationController(
            rootViewController: ProfilePictureVC(
                image: (format == .gif || format == .webp ?
                    nil :
                    UIImage(data: profileData)
                ),
                animatedImage: (format != .gif && format != .webp ?
                    nil :
                    YYImage(data: profileData)
                ),
                title: threadViewModel.displayName
            )
        )
        navController.modalPresentationStyle = .fullScreen
        
        self.transitionToScreen(navController, transitionType: .present)
    }
    
    private func addUsersToOpenGoup(threadViewModel: SessionThreadViewModel, selectedUsers: Set<String>) {
        guard
            let name: String = threadViewModel.openGroupName,
            let server: String = threadViewModel.openGroupServer,
            let roomToken: String = threadViewModel.openGroupRoomToken,
            let publicKey: String = threadViewModel.openGroupPublicKey
        else { return }
        
        let communityUrl: String = SessionUtil.communityUrlFor(
            server: server,
            roomToken: roomToken,
            publicKey: publicKey
        )
        
        dependencies.storage.writeAsync { [dependencies] db in
            try selectedUsers.forEach { userId in
                let thread: SessionThread = try SessionThread
                    .fetchOrCreate(db, id: userId, variant: .contact, shouldBeVisible: nil)
                
                try LinkPreview(
                    url: communityUrl,
                    variant: .openGroupInvitation,
                    title: name
                )
                .save(db)
                
                let interaction: Interaction = try Interaction(
                    threadId: thread.id,
                    authorId: userId,
                    variant: .standardOutgoing,
                    timestampMs: SnodeAPI.currentOffsetTimestampMs(),
                    expiresInSeconds: try? DisappearingMessagesConfiguration
                        .select(.durationSeconds)
                        .filter(id: userId)
                        .filter(DisappearingMessagesConfiguration.Columns.isEnabled == true)
                        .asRequest(of: TimeInterval.self)
                        .fetchOne(db),
                    linkPreviewUrl: communityUrl
                )
                .inserted(db)
                
                try MessageSender.send(
                    db,
                    interaction: interaction,
                    threadId: thread.id,
                    threadVariant: thread.variant,
                    using: dependencies
                )
            }
        }
    }
    
    private func updateBlockedState(
        from oldBlockedState: Bool,
        isBlocked: Bool,
        threadId: String,
        displayName: String
    ) {
        guard oldBlockedState != isBlocked else { return }
        
        dependencies.storage.writeAsync(
            updates: { db in
                try Contact
                    .filter(id: threadId)
                    .updateAllAndConfig(
                        db,
                        Contact.Columns.isBlocked.set(to: isBlocked)
                    )
            },
            completion: { [weak self] db, _ in
                DispatchQueue.main.async {
                    let modal: ConfirmationModal = ConfirmationModal(
                        info: ConfirmationModal.Info(
                            title: (oldBlockedState == false ?
                                "BLOCK_LIST_VIEW_BLOCKED_ALERT_TITLE".localized() :
                                String(
                                    format: "BLOCK_LIST_VIEW_UNBLOCKED_ALERT_TITLE_FORMAT".localized(),
                                    displayName
                                )
                            ),
                            body: (oldBlockedState == true ? .none : .text(
                                String(
                                    format: "BLOCK_LIST_VIEW_BLOCKED_ALERT_MESSAGE_FORMAT".localized(),
                                    displayName
                                )
                            )),
                            accessibility: Accessibility(
                                identifier: "Test_name",
                                label: (oldBlockedState == false ? "User blocked" : "Confirm unblock")
                            ),
                            cancelTitle: "BUTTON_OK".localized(),
                            cancelAccessibility: Accessibility(identifier: "OK_BUTTON"),
                            cancelStyle: .alert_text
                        )
                    )
                    
                    self?.transitionToScreen(modal, transitionType: .present)
                }
            }
        )
    }
}
