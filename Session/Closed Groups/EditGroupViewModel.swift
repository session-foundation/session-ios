// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import YYImage
import DifferenceKit
import SessionUIKit
import SessionSnodeKit
import SessionMessagingKit
import SessionUtilitiesKit
import SignalUtilitiesKit

class EditGroupViewModel: SessionTableViewModel, NavigationItemSource, NavigatableStateHolder, EditableStateHolder, ObservableTableSource {
    public let dependencies: Dependencies
    public let navigatableState: NavigatableState = NavigatableState()
    public let editableState: EditableState<TableItem> = EditableState()
    public let state: TableDataState<Section, TableItem> = TableDataState()
    public let observableState: ObservableTableSourceState<Section, TableItem> = ObservableTableSourceState()
    private let selectedIdsSubject: CurrentValueSubject<Set<String>, Never> = CurrentValueSubject([])
    
    private let threadId: String
    private let userSessionId: SessionId
    private lazy var imagePickerHandler: ImagePickerHandler = ImagePickerHandler(
        onTransition: { [weak self] in self?.transitionToScreen($0, transitionType: $1) },
        onImageDataPicked: { [weak self] resultImageData in
            guard let oldDisplayName: String = self?.oldDisplayName else { return }
            
            self?.updatedDisplayPictureSelected(update: .uploadImageData(resultImageData))
        }
    )
    fileprivate var oldDisplayName: String
    fileprivate var oldDescription: String?
    private var editedName: String?
    private var editedDescription: String?
    private var editDisplayPictureModal: ConfirmationModal?
    private var editDisplayPictureModalInfo: ConfirmationModal.Info?
    
    // MARK: - Initialization
    
    init(threadId: String, using dependencies: Dependencies = Dependencies()) {
        self.dependencies = dependencies
        self.threadId = threadId
        self.userSessionId = getUserSessionId(using: dependencies)
        
        let closedGroup: ClosedGroup? = dependencies[singleton: .storage].read(using: dependencies) { db in
            try ClosedGroup.fetchOne(db, id: threadId)
        }
        self.oldDisplayName = (closedGroup?.name ?? "")
        self.oldDescription = closedGroup?.groupDescription
    }
    
    // MARK: - Config
    
    enum NavState {
        case standard
        case editing
    }
    
    enum NavItem: Equatable {
        case cancel
        case done
    }
    
    public enum Section: SessionTableSection {
        case groupInfo
        case invite
        case members
        
        public var title: String? {
            switch self {
                case .members: return "GROUP_MEMBERS".localized()
                default: return nil
            }
        }
        
        var style: SessionTableSectionStyle {
            switch self {
                case .members: return .titleEdgeToEdgeContent
                default: return .none
            }
        }
    }
    
    public enum TableItem: Equatable, Hashable, Differentiable {
        case avatar
        case groupName
        case groupDescription
        
        case invite
        
        case member(String)
    }
    
    // MARK: - NavigationItemSource
    
    lazy var navState: AnyPublisher<NavState, Never> = Publishers
        .CombineLatest(
            isEditing,
            textChanged
                .handleEvents(
                    receiveOutput: { [weak self] value, item in
                        switch item {
                            case .groupName: self?.editedName = value
                            case .groupDescription: self?.editedDescription = value
                            default: break
                        }
                    }
                )
                .filter { _ in false }
                .prepend((nil, .groupName))
        )
        .map { isEditing, _ -> NavState in (isEditing ? .editing : .standard) }
        .removeDuplicates()
        .prepend(.standard)     // Initial value
        .shareReplay(1)
        .eraseToAnyPublisher()

    lazy var leftNavItems: AnyPublisher<[SessionNavItem<NavItem>], Never> = navState
        .map { navState -> [SessionNavItem<NavItem>] in
            switch navState {
                case .standard: return []
                case .editing:
                    return [
                        SessionNavItem(
                            id: .cancel,
                            systemItem: .cancel,
                            accessibilityIdentifier: "Cancel button"
                        ) { [weak self] in
                            self?.setIsEditing(false)
                            self?.editedName = self?.oldDisplayName
                            self?.editedDescription = self?.oldDescription
                        }
                    ]
            }
        }
        .eraseToAnyPublisher()
    
    lazy var rightNavItems: AnyPublisher<[SessionNavItem<NavItem>], Never> = navState
        .map { [weak self] navState -> [SessionNavItem<NavItem>] in
            switch navState {
                case .standard: return []
                case .editing:
                    return [
                        SessionNavItem(
                            id: .done,
                            systemItem: .done,
                            accessibilityIdentifier: "Done"
                        ) { [weak self] in
                            self?.updateGroupNameAndDescription(
                                updatedName: self?.editedName,
                                updatedDescription: self?.editedDescription
                            ) { didComplete, finalName, finalDescription in
                                guard didComplete else { return }
                                
                                self?.oldDisplayName = finalName
                                self?.oldDescription = finalDescription
                                self?.setIsEditing(false)
                            }
                        }
                    ]
            }
        }
        .eraseToAnyPublisher()

    // MARK: - Content
    
    private struct State: Equatable {
        let group: ClosedGroup
        let profileFront: Profile?
        let profileBack: Profile?
        let members: [WithProfile<GroupMember>]
        let isValid: Bool
        
        static let invalidState: State = State(
            group: ClosedGroup(threadId: "", name: "", formationTimestamp: 0, shouldPoll: false, invited: false),
            profileFront: nil,
            profileBack: nil,
            members: [],
            isValid: false
        )
    }
    
    let title: String = "EDIT_GROUP_ACTION".localized()
    
    lazy var observation: TargetObservation = ObservationBuilder
        .databaseObservation(self) { [dependencies, threadId, userSessionId] db -> State in
            guard let group: ClosedGroup = try ClosedGroup.fetchOne(db, id: threadId) else {
                return State.invalidState
            }
            
            var profileFront: Profile?
            var profileBack: Profile?
            
            if group.displayPictureFilename == nil {
                let frontProfileId: String? = try GroupMember
                    .filter(GroupMember.Columns.groupId == threadId)
                    .filter(GroupMember.Columns.role == GroupMember.Role.standard)
                    .filter(GroupMember.Columns.profileId != userSessionId.hexString)
                    .select(min(GroupMember.Columns.profileId))
                    .asRequest(of: String.self)
                    .fetchOne(db)
                let backProfileId: String? = try GroupMember
                    .filter(GroupMember.Columns.groupId == threadId)
                    .filter(GroupMember.Columns.role == GroupMember.Role.standard)
                    .filter(GroupMember.Columns.profileId != userSessionId.hexString)
                    .filter(GroupMember.Columns.profileId != frontProfileId)
                    .select(max(GroupMember.Columns.profileId))
                    .asRequest(of: String.self)
                    .fetchOne(db)
                
                profileFront = try frontProfileId.map { try Profile.fetchOne(db, id: $0) }
                profileBack = try Profile.fetchOne(db, id: backProfileId ?? userSessionId.hexString)
            }
            
            return State(
                group: group,
                profileFront: profileFront,
                profileBack: profileBack,
                members: try GroupMember
                    .filter(GroupMember.Columns.groupId == threadId)
                    .fetchAllWithProfiles(db),
                isValid: true
            )
        }
        .map { [weak self, dependencies, threadId, userSessionId, selectedIdsSubject] (state: State) -> [SectionModel] in
            guard state.isValid else {
                return [
                    SectionModel(
                        model: .groupInfo,
                        elements: [
                            SessionCell.Info(
                                id: .groupName,
                                title: SessionCell.TextInfo(
                                    "ERROR_UNABLE_TO_FIND_DATA".localized(),
                                    font: .subtitle,
                                    alignment: .center
                                ),
                                styling: SessionCell.StyleInfo(
                                    tintColor: .textSecondary,
                                    alignment: .centerHugging,
                                    customPadding: SessionCell.Padding(top: Values.smallSpacing),
                                    backgroundStyle: .noBackground
                                )
                            )
                        ]
                    )
                ]
            }
            
            let isUpdatedGroup: Bool = (((try? SessionId.Prefix(from: threadId)) ?? .group) == .group)
            let threadVariant: SessionThread.Variant = (isUpdatedGroup ? .group : .legacyGroup)
            let editIcon: UIImage? = UIImage(systemName: "pencil")
            
            return [
                SectionModel(
                    model: .groupInfo,
                    elements: [
                        SessionCell.Info(
                            id: .avatar,
                            accessory: .profile(
                                id: threadId,
                                size: .hero,
                                threadVariant: (isUpdatedGroup ? .group : .legacyGroup),
                                displayPictureFilename: state.group.displayPictureFilename,
                                profile: state.profileFront,
                                profileIcon: .none,
                                additionalProfile: state.profileBack,
                                additionalProfileIcon: .none,
                                accessibility: nil
                            ),
                            styling: SessionCell.StyleInfo(
                                alignment: .centerHugging,
                                customPadding: SessionCell.Padding(bottom: Values.smallSpacing),
                                backgroundStyle: .noBackground
                            ),
                            accessibility: Accessibility(
                                label: "Profile picture"
                            )
                        SessionCell.Info(
                            id: .groupName,
                            leftAccessory: .icon(
                                editIcon?.withRenderingMode(.alwaysTemplate),
                                size: .medium,
                                customTint: .textSecondary
                            ),
                            title: SessionCell.TextInfo(
                                state.group.name,
                                font: .titleLarge,
                                alignment: .center,
                                editingPlaceholder: "EDIT_GROUP_NAME_PLACEHOLDER".localized(),
                                interaction: .editable
                            ),
                            styling: SessionCell.StyleInfo(
                                alignment: .centerHugging,
                                customPadding: SessionCell.Padding(
                                    top: Values.smallSpacing,
                                    leading: -((IconSize.medium.size + (Values.smallSpacing * 2)) / 2),
                                    bottom: Values.smallSpacing,
                                    interItem: 0
                                ),
                                backgroundStyle: .noBackground
                            ),
                            accessibility: Accessibility(
                                identifier: "Group name",
                                label: state.group.name
                            ),
                            onTap: { self?.setIsEditing(true) }
                        )
                    ]
                ),
                SectionModel(
                    model: .invite,
                    elements: [
                        SessionCell.Info(
                            id: .invite,
                            leftAccessory: .icon(UIImage(named: "icon_invite")?.withRenderingMode(.alwaysTemplate)),
                            title: "GROUP_ACTION_INVITE_CONTACTS".localized(),
                            accessibility: Accessibility(
                                identifier: "Invite Contacts",
                                label: "Invite Contacts"
                            ),
                            onTap: { self?.inviteContacts() }
                        )
                    ]
                ),
                SectionModel(
                    model: .members,
                    elements: state.members
                        .sorted()
                        .map { memberInfo -> SessionCell.Info in
                            SessionCell.Info(
                                id: .member(memberInfo.profileId),
                                leftAccessory: .profile(id: memberInfo.profileId, profile: memberInfo.profile),
                                title: (
                                    memberInfo.profile?.displayName() ??
                                    Profile.truncated(id: memberInfo.profileId, truncating: .middle)
                                ),
                                subtitle: (isUpdatedGroup ? memberInfo.value.statusDescription : nil),
                                rightAccessory: {
                                    switch (memberInfo.value.role, memberInfo.value.roleStatus) {
                                        case (.admin, _), (.moderator, _): return nil
                                        case (.standard, .failed), (.standard, .sending):
                                            return .highlightingBackgroundLabel(
                                                title: "context_menu_resend".localized()
                                            )
                                        
                                        // Intentionally including the 'pending' state in here as we want admins to
                                        // be able to remove pending members - to resend the admin will have to remove
                                        // and re-add the member
                                        case (.standard, .pending), (.standard, .accepted), (.zombie, _):
                                            return .radio(
                                                isSelected: selectedIdsSubject.value.contains(memberInfo.profileId)
                                            )
                                    }
                                }(),
                                styling: SessionCell.StyleInfo(
                                    subtitleTintColor: (isUpdatedGroup ? memberInfo.value.statusDescriptionColor : nil),
                                    allowedSeparators: [],
                                    customPadding: SessionCell.Padding(
                                        top: Values.smallSpacing,
                                        bottom: Values.smallSpacing
                                    ),
                                    backgroundStyle: .noBackgroundEdgeToEdge
                                ),
                                onTap: {
                                    switch (memberInfo.value.role, memberInfo.value.roleStatus) {
                                        case (.moderator, _): return
                                        case (.admin, _):
                                            self?.showToast(
                                                text: "EDIT_GROUP_MEMBERS_ERROR_REMOVE_ADMIN".localized(),
                                                backgroundColor: .backgroundSecondary
                                            )
                                            
                                        case (.standard, .failed), (.standard, .sending):
                                            self?.resendInvitation(memberId: memberInfo.profileId)
    
                                        case (.standard, .pending), (.standard, .accepted), (.zombie, _):
                                            if !selectedIdsSubject.value.contains(memberInfo.profileId) {
                                                selectedIdsSubject.send(selectedIdsSubject.value.inserting(memberInfo.profileId))
                                            }
                                            else {
                                                selectedIdsSubject.send(selectedIdsSubject.value.removing(memberInfo.profileId))
                                            }
                                            
                                            // Force the table data to be refreshed (the database wouldn't
                                            // have been changed)
                                            self?.forceRefresh(type: .postDatabaseQuery)
                                    }
                                }
                            )
                        }
                )
            ]
        }
    
    lazy var footerButtonInfo: AnyPublisher<SessionButton.Info?, Never> = selectedIdsSubject
        .prepend([])
        .map { selectedIds in
            SessionButton.Info(
                style: .destructive,
                title: "GROUP_ACTION_REMOVE".localized(),
                isEnabled: !selectedIds.isEmpty,
                onTap: { [weak self] in self?.removeMembers(memberIds: selectedIds) }
            )
        }
        .eraseToAnyPublisher()
    
    // MARK: - Functions
    
    
    private func updateGroupNameAndDescription(
        updatedName: String?,
        updatedDescription: String?,
        onComplete: ((Bool, String, String?) -> ())? = nil
    ) {
        let finalName: String = (updatedName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let finalDescription: String? = updatedDescription.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        
        /// Check if the data violates any of the size constraints
        let maybeErrorString: String? = {
            guard !finalName.isEmpty else { return "EDIT_GROUP_NAME_ERROR_MISSING".localized() }
            guard !Profile.isTooLong(profileName: finalName) else { return "EDIT_GROUP_NAME_ERROR_LONG".localized() }
            guard !SessionUtil.isTooLong(groupDescription: (finalDescription ?? "")) else {
                return "EDIT_GROUP_DESCRIPTION_ERROR_LONG".localized()
            }
            
            return nil
        }()
        
        if let errorString: String = maybeErrorString {
            self.transitionToScreen(
                ConfirmationModal(
                    info: ConfirmationModal.Info(
                        title: "ALERT_ERROR_TITLE".localized(),
                        body: .text(errorString),
                        cancelTitle: "BUTTON_OK".localized(),
                        cancelStyle: .alert_text
                    )
                ),
                transitionType: .present
            )
            onComplete?(false, finalName, finalDescription)
            return
        }
        
        /// Update the group appropriately
        MessageSender
            .updateGroup(
                groupSessionId: threadId,
                name: finalName,
                groupDescription: finalDescription,
                using: dependencies
            )
            .sinkUntilComplete(
                receiveCompletion: { [weak self] result in
                    switch result {
                        case .finished: onComplete?(true, finalName, finalDescription)
                        case .failure:
                            self?.transitionToScreen(
                                ConfirmationModal(
                                    info: ConfirmationModal.Info(
                                        title: "ALERT_ERROR_TITLE".localized(),
                                        body: .text("DEFAULT_OPEN_GROUP_LOAD_ERROR_SUBTITLE".localized()),
                                        cancelTitle: "BUTTON_OK".localized(),
                                        cancelStyle: .alert_text
                                    )
                                ),
                                transitionType: .present
                            )
                            onComplete?(false, finalName, finalDescription)
                    }
                }
            )
    }
    
    private func inviteContacts() {
        let contact: TypedTableAlias<Contact> = TypedTableAlias()
        let groupMember: TypedTableAlias<GroupMember> = TypedTableAlias()
        let currentMemberIds: Set<String> = (tableData
            .first(where: { $0.model == .members })?
            .elements
            .compactMap { item -> String? in
                switch item.id {
                    case .member(let profileId): return profileId
                    default: return nil
                }
            })
            .defaulting(to: [])
            .asSet()
        
        self.transitionToScreen(
            SessionTableViewController(
                viewModel: UserListViewModel<Contact>(
                    title: "GROUP_ACTION_INVITE_CONTACTS".localized(),
                    emptyState: "GROUP_ACTION_INVITE_EMPTY_STATE".localized(),
                    request: """
                        SELECT \(contact.allColumns)
                        FROM \(contact)
                        LEFT JOIN \(groupMember) ON (
                            \(groupMember[.groupId]) = \(threadId) AND
                            \(groupMember[.profileId]) = \(contact[.id])
                        )
                        WHERE \(groupMember[.profileId]) IS NULL
                    """,
                    footerTitle: "GROUP_ACTION_INVITE".localized(),
                    onSubmit: { [dependencies, threadId, oldDisplayName] viewModel, selectedMemberInfo in
                        let updatedMemberIds: Set<String> = currentMemberIds
                            .inserting(contentsOf: selectedMemberInfo.map { $0.profileId }.asSet())
                        
                        guard updatedMemberIds.count <= SessionUtil.sizeMaxGroupMemberCount else {
                            return Fail(error: .error("vc_create_closed_group_too_many_group_members_error".localized()))
                                .eraseToAnyPublisher()
                        }
                        
                        switch try? SessionId.Prefix(from: threadId) {
                            case .group:
                                MessageSender.addGroupMembers(
                                    groupSessionId: threadId,
                                    members: selectedMemberInfo.map { ($0.profileId, $0.profile) },
                                    allowAccessToHistoricMessages: false,
                                    using: dependencies
                                )
                                viewModel?.showToast(
                                    text: (selectedMemberInfo.count == 1 ?
                                        "GROUP_ACTION_INVITE_SENDING".localized() :
                                        "GROUP_ACTION_INVITE_SENDING_MULTIPLE".localized()
                                    ),
                                    backgroundColor: .backgroundSecondary
                                )
                                return Just(()).setFailureType(to: UserListError.self).eraseToAnyPublisher()
                                
                            case .standard: // Assume it's a legacy group
                                return MessageSender.update(
                                    legacyGroupSessionId: threadId,
                                    with: updatedMemberIds,
                                    name: oldDisplayName,
                                    using: dependencies
                                )
                                .mapError { _ in UserListError.error("GROUP_UPDATE_ERROR_TITLE".localized()) }
                                .eraseToAnyPublisher()
                                
                            default:
                                return Fail(error: UserListError.error("GROUP_UPDATE_ERROR_TITLE".localized()))
                                    .eraseToAnyPublisher()
                        }
                    },
                    using: dependencies
                )
            ),
            transitionType: .push
        )
    }
    
    private func resendInvitation(memberId: String) {
        MessageSender.resendInvitation(
            groupSessionId: threadId,
            memberId: memberId,
            using: dependencies
        )
        self.showToast(text: "GROUP_ACTION_INVITE_SENDING".localized())
    }
    
    private func removeMembers(memberIds: Set<String>) {
        guard !memberIds.isEmpty else { return }
        
        switch try? SessionId.Prefix(from: threadId) {
            case .group:
                MessageSender.removeGroupMembers(
                    groupSessionId: threadId,
                    memberIds: memberIds,
                    removeTheirMessages: false,
                    sendMemberChangedMessage: true,
                    using: dependencies
                )
                self.selectedIdsSubject.send([])
            
            case .standard: // Assume it's a legacy group
                let updatedMemberIds: Set<String> = (tableData
                    .first(where: { $0.model == .members })?
                    .elements
                    .compactMap { item -> String? in
                        switch item.id {
                            case .member(let profileId): return profileId
                            default: return nil
                        }
                    })
                    .defaulting(to: [])
                    .asSet()
                    .removing(contentsOf: memberIds)
                
                let viewController = ModalActivityIndicatorViewController(canCancel: false) { [weak self, dependencies, threadId, oldDisplayName] modalActivityIndicator in
                        MessageSender
                            .update(
                                legacyGroupSessionId: threadId,
                                with: updatedMemberIds,
                                name: oldDisplayName,
                                using: dependencies
                            )
                            .eraseToAnyPublisher()
                            .subscribe(on: DispatchQueue.global(qos: .userInitiated))
                            .receive(on: DispatchQueue.main)
                            .sinkUntilComplete(
                                receiveCompletion: { [weak self] result in
                                    modalActivityIndicator.dismiss(completion: {
                                        switch result {
                                            case .finished: self?.selectedIdsSubject.send([])
                                            case .failure:
                                                self?.transitionToScreen(
                                                    ConfirmationModal(
                                                        info: ConfirmationModal.Info(
                                                            title: "ALERT_ERROR_TITLE".localized(),
                                                            body: .text("GROUP_UPDATE_ERROR_TITLE".localized()),
                                                            cancelTitle: "BUTTON_OK".localized(),
                                                            cancelStyle: .alert_text
                                                        )
                                                    ),
                                                    transitionType: .present
                                                )
                                        }
                                    })
                                }
                            )
                }
                self.transitionToScreen(viewController, transitionType: .present)
            
            default:
                self.transitionToScreen(
                    ConfirmationModal(
                        info: ConfirmationModal.Info(
                            title: "ALERT_ERROR_TITLE".localized(),
                            body: .text("GROUP_UPDATE_ERROR_TITLE".localized()),
                            cancelTitle: "BUTTON_OK".localized(),
                            cancelStyle: .alert_text
                        )
                    ),
                    transitionType: .present
                )
        }
    }
}
