// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import YYImage
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit
import SignalUtilitiesKit

class UserListViewModel<T: ProfileAssociated & FetchableRecord>: SessionTableViewModel, NavigatableStateHolder, ObservableTableSource {
    public let dependencies: Dependencies
    public let navigatableState: NavigatableState = NavigatableState()
    public let state: TableDataState<Section, TableItem> = TableDataState()
    public let observableState: ObservableTableSourceState<Section, TableItem> = ObservableTableSourceState()
    private let selectedUsersSubject: CurrentValueSubject<Set<WithProfile<T>>, Never> = CurrentValueSubject([])
    
    public let title: String
    public let emptyState: String?
    private let query: QueryInterfaceRequest<T>?
    private let request: SQLRequest<T>?
    private let onTapAction: OnTapAction
    private let footerTitle: String?
    private let blockingSubmission: Bool
    private let onSubmit: ((UserListViewModel<T>?, Set<WithProfile<T>>) -> AnyPublisher<Void, UserListError>)?
    
    // MARK: - Initialization
    
    init(
        title: String,
        emptyState: String? = nil,
        query: QueryInterfaceRequest<T>,
        onTapAction: OnTapAction = .radio,
        footerTitle: String? = nil,
        blockingSubmission: Bool = false,
        onSubmit: ((UserListViewModel<T>?, Set<WithProfile<T>>) -> AnyPublisher<Void, UserListError>)? = nil,
        using dependencies: Dependencies = Dependencies()
    ) {
        self.dependencies = dependencies
        self.title = title
        self.emptyState = emptyState
        self.query = query
        self.request = nil
        self.onTapAction = onTapAction
        self.footerTitle = footerTitle
        self.blockingSubmission = blockingSubmission
        self.onSubmit = onSubmit
    }
    
    init(
        title: String,
        emptyState: String? = nil,
        request: SQLRequest<T>,
        onTapAction: OnTapAction = .radio,
        footerTitle: String? = nil,
        blockingSubmission: Bool = false,
        onSubmit: ((UserListViewModel<T>?, Set<WithProfile<T>>) -> AnyPublisher<Void, UserListError>)? = nil,
        using dependencies: Dependencies = Dependencies()
    ) {
        self.dependencies = dependencies
        self.title = title
        self.emptyState = emptyState
        self.query = nil
        self.request = request
        self.onTapAction = onTapAction
        self.footerTitle = footerTitle
        self.blockingSubmission = blockingSubmission
        self.onSubmit = onSubmit
    }
    
    // MARK: - Config
    
    public enum Section: SessionTableSection {
        case users
    }
    
    public enum TableItem: Equatable, Hashable, Differentiable {
        case user(String)
    }

    // MARK: - Content
    
    public enum OnTapAction {
        case callback((WithProfile<T>) -> Void)
        case radio
        case custom(rightAccessory: (WithProfile<T>) -> SessionCell.Accessory, onTap: (WithProfile<T>) -> Void)
    }
    
    var emptyStateTextPublisher: AnyPublisher<String?, Never> { Just(emptyState).eraseToAnyPublisher() }
    
    lazy var observation: TargetObservation = ObservationBuilder
        .databaseObservation(self) { [query, request] db -> [WithProfile<T>] in
            switch (query, request) {
                case (.some(let query), _): return try query.fetchAllWithProfiles(db)
                case (_, .some(let request)): return try request.fetchAllWithProfiles(db)
                default: throw StorageError.invalidData
            }
        }
        .map { [weak self, dependencies, onTapAction, selectedUsersSubject] (users: [WithProfile<T>]) -> [SectionModel] in
            return [
                SectionModel(
                    model: .users,
                    elements: users
                        .sorted()
                        .map { userInfo -> SessionCell.Info in
                            let rightAccessory: SessionCell.Accessory? = {
                                switch onTapAction {
                                    case .callback: return nil
                                    case .custom(let accessoryGenerator, _): return accessoryGenerator(userInfo)
                                    case .radio:
                                        return .radio(
                                            isSelected: selectedUsersSubject.value.contains(where: { selectedUserInfo in
                                                selectedUserInfo.profileId == userInfo.profileId
                                            })
                                        )
                                }
                            }()
                            
                            return SessionCell.Info(
                                id: .user(userInfo.profileId),
                                leftAccessory: .profile(id: userInfo.profileId, profile: userInfo.profile),
                                title: (
                                    userInfo.profile?.displayName() ??
                                    Profile.truncated(id: userInfo.profileId, truncating: .middle)
                                ),
                                subtitle: userInfo.itemDescription(using: dependencies),
                                rightAccessory: rightAccessory,
                                styling: SessionCell.StyleInfo(
                                    subtitleTintColor: userInfo.itemDescriptionColor(using: dependencies),
                                    allowedSeparators: [],
                                    customPadding: SessionCell.Padding(
                                        top: Values.smallSpacing,
                                        bottom: Values.smallSpacing
                                    ),
                                    backgroundStyle: .noBackgroundEdgeToEdge
                                ),
                                onTap: {
                                    // Trigger any 'onTap' actions
                                    switch onTapAction {
                                        case .callback(let callback): callback(userInfo)
                                        case .custom(_, let callback): callback(userInfo)
                                        case .radio: break
                                    }
                                    
                                    // Only update the selection if the accessory is a 'radio'
                                    guard case .radio = rightAccessory else { return }
                                    
                                    // Toggle the selection
                                    if !selectedUsersSubject.value.contains(userInfo) {
                                        selectedUsersSubject.send(selectedUsersSubject.value.inserting(userInfo))
                                    }
                                    else {
                                        selectedUsersSubject.send(selectedUsersSubject.value.removing(userInfo))
                                    }
                                    
                                    // Force the table data to be refreshed (the database wouldn't have been changed)
                                    self?.forceRefresh(type: .postDatabaseQuery)
                                }
                            )
                        }
                )
            ]
        }
    
    lazy var footerButtonInfo: AnyPublisher<SessionButton.Info?, Never> = selectedUsersSubject
        .prepend([])
        .map { [weak self, dependencies, footerTitle, blockingSubmission, onSubmit] selectedUsers -> SessionButton.Info? in
            guard
                let title: String = footerTitle,
                let onSubmit: (UserListViewModel<T>?, Set<WithProfile<T>>) -> AnyPublisher<Void, UserListError> = onSubmit
            else { return nil }
            
            return SessionButton.Info(
                style: .bordered,
                title: title,
                isEnabled: !selectedUsers.isEmpty,
                onTap: {
                    let triggerSubmission: (ModalActivityIndicatorViewController?) -> () = { modalActivityIndicator in
                        onSubmit(self, selectedUsers)
                            .subscribe(on: DispatchQueue.global(qos: .userInitiated), using: dependencies)
                            .receive(on: DispatchQueue.main, using: dependencies)
                            .sinkUntilComplete(
                                receiveCompletion: { result in
                                    switch result {
                                        case .finished:
                                            self?.selectedUsersSubject.send([])
                                            self?.forceRefresh()    // Just in case the filter was impacted
                                            modalActivityIndicator?.dismiss(completion: {})
                                            
                                        case .failure(let error):
                                            let showAlert: () -> () = {
                                                self?.transitionToScreen(
                                                    ConfirmationModal(
                                                        info: ConfirmationModal.Info(
                                                            title: "ALERT_ERROR_TITLE".localized(),
                                                            body: error.body,
                                                            cancelTitle: "BUTTON_OK".localized(),
                                                            cancelStyle: .alert_text
                                                        )
                                                    ),
                                                    transitionType: .present
                                                )
                                            }
                                            
                                            switch blockingSubmission {
                                                case false: showAlert()
                                                case true: modalActivityIndicator?.dismiss(completion: { showAlert() })
                                            }
                                    }
                                }
                            )
                    }
                    
                    // Only show the blocking loading indicator if the submission should be blocking
                    switch blockingSubmission {
                        case false: triggerSubmission(nil)
                        case true:
                            self?.transitionToScreen(
                                ModalActivityIndicatorViewController(canCancel: false) { modalActivityIndicator in
                                    triggerSubmission(modalActivityIndicator)
                                },
                                transitionType: .present
                            )
                    }
                }
            )
        }
        .eraseToAnyPublisher()
}

// MARK: - UserListError

public enum UserListError: Error {
    case error(String)
    
    var body: ConfirmationModal.Info.Body {
        switch self {
            case .error(let content): return .text(content)
        }
    }
}
