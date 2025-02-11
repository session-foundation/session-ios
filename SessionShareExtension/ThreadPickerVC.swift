// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Combine
import GRDB
import DifferenceKit
import SessionUIKit
import SignalUtilitiesKit
import SessionMessagingKit
import SessionSnodeKit
import SessionUtilitiesKit

final class ThreadPickerVC: UIViewController, UITableViewDataSource, UITableViewDelegate, AttachmentApprovalViewControllerDelegate {
    private let viewModel: ThreadPickerViewModel
    private var dataChangeObservable: DatabaseCancellable? {
        didSet { oldValue?.cancel() }   // Cancel the old observable if there was one
    }
    private var hasLoadedInitialData: Bool = false
    
    var shareNavController: ShareNavController?
    
    // MARK: - Intialization
    
    init(using dependencies: Dependencies) {
        viewModel = ThreadPickerViewModel(using: dependencies)
        
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
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

    private lazy var tableView: UITableView = {
        let tableView: UITableView = UITableView()
        tableView.themeBackgroundColor = .backgroundPrimary
        tableView.separatorStyle = .none
        tableView.register(view: SimplifiedConversationCell.self)
        tableView.showsVerticalScrollIndicator = false
        tableView.dataSource = self
        tableView.delegate = self
        
        return tableView
    }()
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        navigationItem.titleView = titleLabel
        
        view.themeBackgroundColor = .backgroundPrimary
        view.addSubview(tableView)
        view.addSubview(databaseErrorLabel)
        
        setupLayout()
        
        // Notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive(_:)),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive(_:)),
            name: UIApplication.didEnterBackgroundNotification, object: nil
        )
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        startObservingChanges()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        stopObservingChanges()
        
        // When the thread picker disappears it means the user has left the screen (this will be called
        // whether the user has sent the message or cancelled sending)
        LibSession.suspendNetworkAccess()
        viewModel.dependencies.storage.suspendDatabaseAccess()
        Log.flush()
    }
    
    @objc func applicationDidBecomeActive(_ notification: Notification) {
        /// Need to dispatch to the next run loop to prevent a possible crash caused by the database resuming mid-query
        DispatchQueue.main.async { [weak self] in
            self?.startObservingChanges()
        }
    }
    
    @objc func applicationDidResignActive(_ notification: Notification) {
        stopObservingChanges()
    }
    
    // MARK: Layout
    
    private func setupLayout() {
        tableView.pin(to: view)
        
        databaseErrorLabel.pin(.top, to: .top, of: view, withInset: Values.massiveSpacing)
        databaseErrorLabel.pin(.leading, to: .leading, of: view, withInset: Values.veryLargeSpacing)
        databaseErrorLabel.pin(.trailing, to: .trailing, of: view, withInset: -Values.veryLargeSpacing)
    }
    
    // MARK: - Updating
    
    private func startObservingChanges() {
        guard dataChangeObservable == nil else { return }
        
        // Start observing for data changes
        dataChangeObservable = Storage.shared.start(
            viewModel.observableViewData,
            onError:  { [weak self] _ in self?.databaseErrorLabel.isHidden = Storage.shared.isValid },
            onChange: { [weak self] viewData in
                // The defaul scheduler emits changes on the main thread
                self?.handleUpdates(viewData)
            }
        )
    }
    
    private func stopObservingChanges() {
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
        cell.update(with: self.viewModel.viewData[indexPath.row])
        
        return cell
    }
    
    // MARK: - Interaction
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        
        ShareNavController.attachmentPrepPublisher?
            .subscribe(on: DispatchQueue.global(qos: .userInitiated))
            .receive(on: DispatchQueue.main)
            .sinkUntilComplete(
                receiveValue: { [weak self, dependencies = self.viewModel.dependencies] attachments in
                    guard
                        let strongSelf = self,
                        let approvalVC: UINavigationController = AttachmentApprovalViewController.wrappedInNavController(
                            threadId: strongSelf.viewModel.viewData[indexPath.row].threadId,
                            threadVariant: strongSelf.viewModel.viewData[indexPath.row].threadVariant,
                            attachments: attachments,
                            approvalDelegate: strongSelf,
                            using: dependencies
                        )
                    else { return }
                    
                    self?.navigationController?.present(approvalVC, animated: true, completion: nil)
                }
            )
    }
    
    func attachmentApproval(
        _ attachmentApproval: AttachmentApprovalViewController,
        didApproveAttachments attachments: [SignalAttachment],
        forThreadId threadId: String,
        threadVariant: SessionThread.Variant,
        messageText: String?
    ) {
        // Sharing a URL or plain text will populate the 'messageText' field so in those
        // cases we should ignore the attachments
        let isSharingUrl: Bool = (attachments.count == 1 && attachments[0].isUrl)
        let isSharingText: Bool = (attachments.count == 1 && attachments[0].isText)
        let finalAttachments: [SignalAttachment] = (isSharingUrl || isSharingText ? [] : attachments)
        let body: String? = (
            isSharingUrl && (messageText?.isEmpty == true || attachments[0].linkPreviewDraft == nil) ?
            (
                (messageText?.isEmpty == true || (attachments[0].text() == messageText) ?
                    attachments[0].text() :
                    "\(attachments[0].text() ?? "")\n\n\(messageText ?? "")" // stringlint:ignore
                )
            ) :
            messageText
        )
        
        shareNavController?.dismiss(animated: true, completion: nil)
        
        ModalActivityIndicatorViewController.present(fromViewController: shareNavController!, canCancel: false, message: "sending".localized()) { [dependencies = viewModel.dependencies] activityIndicator in
            dependencies.storage.resumeDatabaseAccess()
            LibSession.resumeNetworkAccess()
            
            let swarmPublicKey: String = {
                switch threadVariant {
                    case .contact, .legacyGroup, .group: return threadId
                    case .community: return getUserHexEncodedPublicKey(using: dependencies)
                }
            }()
            
            /// When we prepare the message we set the timestamp to be the `SnodeAPI.currentOffsetTimestampMs()`
            /// but won't actually have a value because the share extension won't have talked to a service node yet which can cause
            /// issues with Disappearing Messages, as a result we need to explicitly `getNetworkTime` in order to ensure it's accurate
            LibSession
                .getSwarm(swarmPublicKey: swarmPublicKey)
                .tryFlatMapWithRandomSnode(using: dependencies) { snode in
                    SnodeAPI.getNetworkTime(from: snode, using: dependencies)
                }
                .subscribe(on: DispatchQueue.global(qos: .userInitiated))
                .flatMap { _ in
                    dependencies.storage.writePublisher { db -> MessageSender.PreparedSendData in
                        guard let thread: SessionThread = try SessionThread.fetchOne(db, id: threadId) else {
                            throw MessageSenderError.noThread
                        }
                        
                        // Update the thread to be visible (if it isn't already)
                        if !thread.shouldBeVisible || thread.pinnedPriority == LibSession.hiddenPriority {
                            _ = try SessionThread
                                .filter(id: threadId)
                                .updateAllAndConfig(
                                    db,
                                    SessionThread.Columns.shouldBeVisible.set(to: true),
                                    SessionThread.Columns.pinnedPriority.set(to: LibSession.visiblePriority),
                                    using: dependencies
                                )
                        }
                        
                        // Create the interaction
                        let sentTimestampMs: Int64 = SnodeAPI.currentOffsetTimestampMs()
                        let destinationDisappearingMessagesConfiguration: DisappearingMessagesConfiguration? = try? DisappearingMessagesConfiguration
                            .filter(id: threadId)
                            .filter(DisappearingMessagesConfiguration.Columns.isEnabled == true)
                            .fetchOne(db)
                        let interaction: Interaction = try Interaction(
                            threadId: threadId,
                            threadVariant: threadVariant,
                            authorId: getUserHexEncodedPublicKey(db),
                            variant: .standardOutgoing,
                            body: body,
                            timestampMs: sentTimestampMs,
                            hasMention: Interaction.isUserMentioned(db, threadId: threadId, body: body),
                            expiresInSeconds: destinationDisappearingMessagesConfiguration?.durationSeconds,
                            expiresStartedAtMs: (destinationDisappearingMessagesConfiguration?.type == .disappearAfterSend ? Double(sentTimestampMs) : nil),
                            linkPreviewUrl: (isSharingUrl ? attachments.first?.linkPreviewDraft?.urlString : nil)
                        ).inserted(db)
                        
                        guard let interactionId: Int64 = interaction.id else {
                            throw StorageError.failedToSave
                        }
                        
                        // If the user is sharing a Url, there is a LinkPreview and it doesn't match an existing
                        // one then add it now
                        if
                            isSharingUrl,
                            let linkPreviewDraft: LinkPreviewDraft = attachments.first?.linkPreviewDraft,
                            (try? interaction.linkPreview.isEmpty(db)) == true
                        {
                            try LinkPreview(
                                url: linkPreviewDraft.urlString,
                                title: linkPreviewDraft.title,
                                attachmentId: LinkPreview
                                    .generateAttachmentIfPossible(
                                        imageData: linkPreviewDraft.jpegImageData,
                                        type: .jpeg
                                    )?
                                    .inserted(db)
                                    .id
                            ).insert(db)
                        }
                        
                        // Prepare any attachments
                        try Attachment.process(
                            db,
                            data: Attachment.prepare(attachments: finalAttachments),
                            for: interactionId
                        )
                        
                        // Prepare the message send data
                        return try MessageSender
                            .preparedSendData(
                                db,
                                interaction: interaction,
                                threadId: threadId,
                                threadVariant: threadVariant,
                                using: dependencies
                            )
                    }
                }
                .flatMap { MessageSender.performUploadsIfNeeded(preparedSendData: $0, using: dependencies) }
                .flatMap { MessageSender.sendImmediate(data: $0, using: dependencies) }
                .receive(on: DispatchQueue.main)
                .sinkUntilComplete(
                    receiveCompletion: { [weak self] result in
                        LibSession.suspendNetworkAccess()
                        dependencies.storage.suspendDatabaseAccess()
                        Log.flush()
                        activityIndicator.dismiss { }
                        
                        switch result {
                            case .finished: self?.shareNavController?.shareViewWasCompleted()
                            case .failure(let error): self?.shareNavController?.shareViewFailed(error: error)
                        }
                    }
                )
        }
    }

    func attachmentApprovalDidCancel(_ attachmentApproval: AttachmentApprovalViewController) {
        dismiss(animated: true, completion: nil)
    }

    func attachmentApproval(_ attachmentApproval: AttachmentApprovalViewController, didChangeMessageText newMessageText: String?) {
    }
    
    func attachmentApproval(_ attachmentApproval: AttachmentApprovalViewController, didRemoveAttachment attachment: SignalAttachment) {
    }
    
    func attachmentApprovalDidTapAddMore(_ attachmentApproval: AttachmentApprovalViewController) {
    }
}
