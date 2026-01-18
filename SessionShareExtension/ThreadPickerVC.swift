// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Combine
import UniformTypeIdentifiers
import GRDB
import DifferenceKit
import SessionUIKit
import SignalUtilitiesKit
import SessionMessagingKit
import SessionNetworkingKit
import SessionUtilitiesKit

final class ThreadPickerVC: UIViewController, UITableViewDataSource, UITableViewDelegate, AttachmentApprovalViewControllerDelegate, ThemedNavigation {
    private let viewModel: ThreadPickerViewModel
    private var dataChangeObservable: DatabaseCancellable? {
        didSet { oldValue?.cancel() }   // Cancel the old observable if there was one
    }
    private var hasLoadedInitialData: Bool = false
    public var navigationBackground: ThemeValue? { .backgroundPrimary }
    
    var shareNavController: ShareNavController?
    
    // MARK: - Intialization
    
    init(
        userMetadata: ExtensionHelper.UserMetadata?,
        itemProviders: [NSItemProvider]?,
        using dependencies: Dependencies
    ) {
        viewModel = ThreadPickerViewModel(
            userMetadata: userMetadata,
            itemProviders: itemProviders,
            using: dependencies
        )
        
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - UI
    
    private lazy var titleLabel: UILabel = {
        let titleLabel: UILabel = UILabel()
        titleLabel.font = .boldSystemFont(ofSize: Values.veryLargeFontSize)
        titleLabel.text = "shareToSession"
            .put(key: "app_name", value: Constants.app_name)
            .localized()
        titleLabel.themeTextColor = .textPrimary
        
        return titleLabel
    }()
    
    private lazy var databaseErrorLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = .systemFont(ofSize: Values.mediumFontSize)
        result.text = "shareExtensionDatabaseError".localized()
        result.textAlignment = .center
        result.themeTextColor = .textPrimary
        result.numberOfLines = 0
        result.isHidden = true
        
        return result
    }()
    
    private lazy var noAccountErrorLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = .systemFont(ofSize: Values.mediumFontSize)
        result.text = "shareExtensionNoAccountError"
            .put(key: "app_name", value: Constants.app_name)
            .localized()
        result.textAlignment = .center
        result.themeTextColor = .textPrimary
        result.numberOfLines = 0
        result.isHidden = (viewModel.userMetadata != nil)
        
        return result
    }()

    private lazy var tableView: UITableView = {
        let result: UITableView = UITableView()
        result.themeBackgroundColor = .backgroundPrimary
        result.separatorStyle = .none
        result.register(view: SimplifiedConversationCell.self)
        result.showsVerticalScrollIndicator = false
        result.dataSource = self
        result.delegate = self
        result.isHidden = (viewModel.userMetadata == nil)
        
        return result
    }()
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        navigationItem.titleView = titleLabel
        
        view.themeBackgroundColor = .backgroundPrimary
        view.addSubview(tableView)
        view.addSubview(databaseErrorLabel)
        view.addSubview(noAccountErrorLabel)
        
        setupLayout()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        /// Apply the nav styling in `viewWillAppear` instead of `viewDidLoad` as it's possible the nav stack isn't fully setup
        /// and could crash when trying to access it (whereas by the time `viewWillAppear` is called it should be setup)
        ThemeManager.applyNavigationStylingIfNeeded(to: self)
        startObservingChanges()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        stopObservingChanges()
        
        // When the thread picker disappears it means the user has left the screen (this will be called
        // whether the user has sent the message or cancelled sending)
        viewModel.dependencies.mutate(cache: .libSessionNetwork) { $0.suspendNetworkAccess() }
        viewModel.dependencies[singleton: .storage].suspendDatabaseAccess()
        Log.flush()
    }
    
    // MARK: Layout
    
    private func setupLayout() {
        tableView.pin(to: view)
        
        databaseErrorLabel.pin(.top, to: .top, of: view, withInset: Values.massiveSpacing)
        databaseErrorLabel.pin(.leading, to: .leading, of: view, withInset: Values.veryLargeSpacing)
        databaseErrorLabel.pin(.trailing, to: .trailing, of: view, withInset: -Values.veryLargeSpacing)
        
        noAccountErrorLabel.pin(.top, to: .top, of: view, withInset: Values.massiveSpacing)
        noAccountErrorLabel.pin(.leading, to: .leading, of: view, withInset: Values.veryLargeSpacing)
        noAccountErrorLabel.pin(.trailing, to: .trailing, of: view, withInset: -Values.veryLargeSpacing)
    }
    
    // MARK: - Updating
    
    private func startObservingChanges() {
        guard dataChangeObservable == nil else { return }
        
        tableView.isHidden = !noAccountErrorLabel.isHidden
        
        guard viewModel.userMetadata != nil else { return }
        
        // Start observing for data changes
        dataChangeObservable = self.viewModel.dependencies[singleton: .storage].start(
            viewModel.observableViewData,
            onError:  { [weak self, dependencies = self.viewModel.dependencies] _ in
                self?.databaseErrorLabel.isHidden = dependencies[singleton: .storage].isValid
            },
            onChange: { [weak self] viewData in
                // The defaul scheduler emits changes on the main thread
                self?.handleUpdates(viewData)
            }
        )
    }
    
    private func stopObservingChanges() {
        dataChangeObservable?.cancel()
        dataChangeObservable = nil
    }
    
    private func handleUpdates(_ updatedViewData: [SessionThreadViewModel]) {
        // Ensure the first load runs without animations (if we don't do this the cells will animate
        // in from a frame of CGRect.zero)
        guard hasLoadedInitialData else {
            hasLoadedInitialData = true
            UIView.performWithoutAnimation { handleUpdates(updatedViewData) }
            return
        }
        
        // Reload the table content (animate changes after the first load)
        tableView.reload(
            using: StagedChangeset(source: viewModel.viewData, target: updatedViewData),
            with: .automatic,
            interrupt: { $0.changeCount > 100 }    // Prevent too many changes from causing performance issues
        ) { [weak self] updatedData in
            self?.viewModel.updateData(updatedData)
        }
    }
    
    // MARK: - UITableViewDataSource
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.viewModel.viewData.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell: SimplifiedConversationCell = tableView.dequeue(type: SimplifiedConversationCell.self, for: indexPath)
        cell.update(with: self.viewModel.viewData[indexPath.row], using: viewModel.dependencies)
        
        return cell
    }
    
    // MARK: - Interaction
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        
        Task(priority: .userInitiated) { [weak self] in
            let attachments: [PendingAttachment] = await ShareNavController.pendingAttachments.stream
                .compactMap { $0 }
                .first(where: { _ in true })
                .defaulting(to: [])
            
            guard
                !attachments.isEmpty,
                let self = self
            else {
                self?.shareNavController?.shareViewFailed(error: AttachmentError.invalidData)
                return
            }
            
            let viewController: AttachmentApprovalViewController = AttachmentApprovalViewController(
                mode: .modal,
                delegate: self,
                threadId: viewModel.viewData[indexPath.row].threadId,
                threadVariant: viewModel.viewData[indexPath.row].threadVariant,
                attachments: attachments,
                messageText: nil,
                quoteViewModel: nil,
                disableLinkPreviewImageDownload: (viewModel.viewData[indexPath.row].threadCanUpload != true),
                didLoadLinkPreview: { [weak self] result in
                    self?.viewModel.didLoadLinkPreview(result: result)
                },
                onQuoteCancelled: nil,
                using: viewModel.dependencies
            )
            
            let navController = StyledNavigationController(rootViewController: viewController)
            navController.modalPresentationStyle = .fullScreen
            
            navigationController?.present(navController, animated: true, completion: nil)
        }
    }
    
    func attachmentApproval(
        _ attachmentApproval: AttachmentApprovalViewController,
        didApproveAttachments attachments: [PendingAttachment],
        forThreadId threadId: String,
        threadVariant: SessionThread.Variant,
        messageText: String?,
        quoteViewModel: QuoteViewModel?
    ) {
        // Sharing a URL or plain text will populate the 'messageText' field so in those
        // cases we should ignore the attachments
        let isSharingUrl: Bool = (attachments.count == 1 && attachments[0].utType.conforms(to: .url))
        let isSharingText: Bool = {
            guard attachments.count == 1 else { return false }
            
            switch attachments[0].source {
                case .text: return true
                default: return false
            }
        }()
        let finalPendingAttachments: [PendingAttachment] = (isSharingUrl || isSharingText ? [] : attachments)
        let body: String? = {
            guard isSharingUrl else { return messageText }
            
            let attachmentText: String? = attachments[0].toText()
            
            return (messageText?.isEmpty == true || attachmentText == messageText ?
                attachmentText :
                "\(attachmentText ?? "")\n\n\(messageText ?? "")" // stringlint:ignore
            )
        }()
        let linkPreviewViewModel: LinkPreviewViewModel? = (isSharingUrl ?
            viewModel.linkPreviewViewModels.first(where: { $0.urlString == body }) :
            nil
        )
        let userSessionId: SessionId = viewModel.dependencies[cache: .general].sessionId
        let swarmPublicKey: String = {
            switch threadVariant {
                case .contact, .legacyGroup, .group: return threadId
                case .community: return userSessionId.hexString
            }
        }()
        
        shareNavController?.dismiss(animated: true, completion: nil)
        
        let indicator: ModalActivityIndicatorViewController = ModalActivityIndicatorViewController(
            canCancel: false,
            message: "sending".localized()
        )
        shareNavController?.present(indicator, animated: false)
        
        Task(priority: .userInitiated) { [weak self, indicator, dependencies = viewModel.dependencies] in
            dependencies[singleton: .storage].resumeDatabaseAccess()
            dependencies.mutate(cache: .libSessionNetwork) { $0.resumeNetworkAccess() }
            
            var sharedInteractionId: Int64?
            
            do {
                /// When we prepare the message we set the timestamp to be the `dependencies[cache: .snodeAPI].currentOffsetTimestampMs()`
                /// but won't actually have a value because the share extension won't have talked to a service node yet which can cause
                /// issues with Disappearing Messages, as a result we need to explicitly `getNetworkTime` in order to ensure it's accurate
                /// before we create the interaction
                // FIXME: Make this async/await when the refactored networking is merged
                var swarm: Set<LibSession.Snode> = try await dependencies[singleton: .network]
                    .getSwarm(for: swarmPublicKey)
                    .values
                    .first(where: { _ in true }) ?? { throw AttachmentError.uploadFailed }()
                let snode: LibSession.Snode = try dependencies.popRandomElement(&swarm) ?? {
                    throw SnodeAPIError.ranOutOfRandomSnodes(nil)
                }()
                try Task.checkCancellation()
                
                /// If there is a `LinkPreviewViewModel` then we may need to add it, so generate it's attachment if possible
                var linkPreviewPreparedAttachment: PreparedAttachment?
                    
                if let linkPreviewViewModel: LinkPreviewViewModel = linkPreviewViewModel {
                    linkPreviewPreparedAttachment = try? await LinkPreview.prepareAttachmentIfPossible(
                        urlString: linkPreviewViewModel.urlString,
                        imageSource: linkPreviewViewModel.imageSource,
                        using: dependencies
                    )
                }
                
                /// Prepare any attachment to be sent
                var finalAttachments: [Attachment] = try await AttachmentUploadJob.preparePriorToUpload(
                    attachments: finalPendingAttachments,
                    using: dependencies
                )
                
                typealias ShareDatabaseData = (
                    message: Message,
                    destination: Message.Destination,
                    interactionId: Int64?,
                    authMethod: AuthenticationMethod,
                    attachmentsNeedingUpload: [Attachment]
                )
                
                let shareData: ShareDatabaseData = try await dependencies[singleton: .storage].writeAsync { db in
                    guard let thread: SessionThread = try SessionThread.fetchOne(db, id: threadId) else {
                        throw MessageSenderError.noThread
                    }
                    
                    /// Update the thread to be visible (if it isn't already)
                    if !thread.shouldBeVisible || thread.pinnedPriority == LibSession.hiddenPriority {
                        try SessionThread.updateVisibility(
                            db,
                            threadId: threadId,
                            threadVariant: threadVariant,
                            isVisible: true,
                            additionalChanges: [SessionThread.Columns.isDraft.set(to: false)],
                            using: dependencies
                        )
                    }
                    
                    /// Create the interaction
                    let sentTimestampMs: Int64 = dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
                    let destinationDisappearingMessagesConfiguration: DisappearingMessagesConfiguration? = try? DisappearingMessagesConfiguration
                        .filter(id: threadId)
                        .filter(DisappearingMessagesConfiguration.Columns.isEnabled == true)
                        .fetchOne(db)
                    let interaction: Interaction = try Interaction(
                        threadId: threadId,
                        threadVariant: threadVariant,
                        authorId: userSessionId.hexString,
                        variant: .standardOutgoing,
                        body: body,
                        timestampMs: sentTimestampMs,
                        hasMention: Interaction.isUserMentioned(db, threadId: threadId, body: body, using: dependencies),
                        expiresInSeconds: destinationDisappearingMessagesConfiguration?.expiresInSeconds(),
                        expiresStartedAtMs: destinationDisappearingMessagesConfiguration?.initialExpiresStartedAtMs(
                            sentTimestampMs: Double(sentTimestampMs)
                        ),
                        linkPreviewUrl: linkPreviewViewModel?.urlString,
                        using: dependencies
                    ).inserted(db)
                    sharedInteractionId = interaction.id
                    
                    guard let interactionId: Int64 = interaction.id else {
                        throw StorageError.failedToSave
                    }
                    
                    // If the user is sharing a Url, there is a LinkPreview and it doesn't match an existing
                    // one then add it now
                    if
                        isSharingUrl,
                        let linkPreviewViewModel: LinkPreviewViewModel = linkPreviewViewModel,
                        (try? interaction.linkPreview.isEmpty(db)) == true
                    {
                        try LinkPreview(
                            url: linkPreviewViewModel.urlString,
                            title: linkPreviewViewModel.title,
                            attachmentId: linkPreviewPreparedAttachment?
                                .attachment
                                .inserted(db)
                                .id,
                            using: dependencies
                        ).insert(db)
                    }
                    
                    // Link any attachments to their interaction
                    try AttachmentUploadJob.link(
                        db,
                        attachments: finalAttachments,
                        toInteractionWithId: interactionId
                    )
                    
                    // Using the same logic as the `MessageSendJob` retrieve
                    let authMethod: AuthenticationMethod = try Authentication.with(
                        db,
                        threadId: threadId,
                        threadVariant: threadVariant,
                        using: dependencies
                    )
                    let attachmentState: MessageSendJob.AttachmentState = try MessageSendJob
                        .fetchAttachmentState(db, interactionId: interactionId, using: dependencies)
                    let attachmentsNeedingUpload: [Attachment] = try Attachment
                        .filter(ids: attachmentState.allAttachmentIds)
                        .fetchAll(db)
                    let visibleMessage: VisibleMessage = VisibleMessage.from(db, interaction: interaction)
                    let destination: Message.Destination = try Message.Destination.from(
                        db,
                        threadId: threadId,
                        threadVariant: threadVariant
                    )
                    
                    return (visibleMessage, destination, interaction.id, authMethod, attachmentsNeedingUpload)
                }
                try Task.checkCancellation()
                
                /// Perform any uploads that are needed
                let uploadedAttachments: [(attachment: Attachment, fileId: String)] = (shareData.attachmentsNeedingUpload.isEmpty ?
                    [] :
                    try await withThrowingTaskGroup(of: (attachment: Attachment, response: FileUploadResponse).self) { group in
                        shareData.attachmentsNeedingUpload.forEach { attachment in
                            group.addTask {
                                try await AttachmentUploadJob.upload(
                                    attachment: attachment,
                                    threadId: threadId,
                                    interactionId: shareData.interactionId,
                                    messageSendJobId: nil,
                                    authMethod: shareData.authMethod,
                                    onEvent: AttachmentUploadJob.standardEventHandling(using: dependencies),
                                    using: dependencies
                                )
                            }
                        }
                        
                    return try await group.reduce(into: []) { result, next in
                        result.append((next.attachment, next.response.id))
                    }
                })
                
                let request: Network.PreparedRequest<Message> = try MessageSender.preparedSend(
                    message: shareData.message,
                    to: shareData.destination,
                    namespace: shareData.destination.defaultNamespace,
                    interactionId: shareData.interactionId,
                    attachments: uploadedAttachments,
                    authMethod: shareData.authMethod,
                    onEvent: MessageSender.standardEventHandling(using: dependencies),
                    using: dependencies
                )
                
                // FIXME: Make this async/await when the refactored networking is merged
                let response: Message = try await request
                    .send(using: dependencies)
                    .values
                    .first(where: { _ in true })?.1 ?? { throw AttachmentError.uploadFailed }()
                try Task.checkCancellation()
                
                /// Need to actually save the uploaded attachments now that we are done
                if !uploadedAttachments.isEmpty {
                    try? await dependencies[singleton: .storage].writeAsync { db in
                        uploadedAttachments.forEach { attachment, _ in
                            try? attachment.upsert(db)
                        }
                    }
                }
                
                dependencies.mutate(cache: .libSessionNetwork) { $0.suspendNetworkAccess() }
                dependencies[singleton: .storage].suspendDatabaseAccess()
                Log.flush()
                
                await MainActor.run { [weak self] in
                    indicator.dismiss()
                    
                    self?.shareNavController?.shareViewWasCompleted(
                        threadId: threadId,
                        interactionId: sharedInteractionId
                    )
                }
            }
            catch {
                dependencies.mutate(cache: .libSessionNetwork) { $0.suspendNetworkAccess() }
                dependencies[singleton: .storage].suspendDatabaseAccess()
                Log.flush()
                indicator.dismiss()
                self?.shareNavController?.shareViewFailed(error: error)
            }
        }
    }

    func attachmentApprovalDidCancel(_ attachmentApproval: AttachmentApprovalViewController) {
        dismiss(animated: true, completion: nil)
    }

    func attachmentApproval(_ attachmentApproval: AttachmentApprovalViewController, didChangeMessageText newMessageText: String?) {
    }
    
    func attachmentApproval(_ attachmentApproval: AttachmentApprovalViewController, didRemoveAttachment attachment: PendingAttachment) {
    }
    
    func attachmentApprovalDidTapAddMore(_ attachmentApproval: AttachmentApprovalViewController) {
    }
}
