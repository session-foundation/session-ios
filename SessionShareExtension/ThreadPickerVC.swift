// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Combine
import GRDB
import DifferenceKit
import SessionUIKit
import SignalUtilitiesKit
import SessionMessagingKit

final class ThreadPickerVC: UIViewController, UITableViewDataSource, UITableViewDelegate, AttachmentApprovalViewControllerDelegate {
    private let viewModel: ThreadPickerViewModel = ThreadPickerViewModel()
    private var dataChangeObservable: DatabaseCancellable?
    private var hasLoadedInitialData: Bool = false
    
    var shareNavController: ShareNavController?
    
    // MARK: - Intialization
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - UI
    
    private lazy var titleLabel: UILabel = {
        let titleLabel: UILabel = UILabel()
        titleLabel.font = .boldSystemFont(ofSize: Values.veryLargeFontSize)
        titleLabel.text = "vc_share_title".localized()
        titleLabel.themeTextColor = .textPrimary
        
        return titleLabel
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
        
        // Stop observing database changes
        dataChangeObservable?.cancel()
    }
    
    @objc func applicationDidBecomeActive(_ notification: Notification) {
        startObservingChanges()
    }
    
    @objc func applicationDidResignActive(_ notification: Notification) {
        // Stop observing database changes
        dataChangeObservable?.cancel()
    }
    
    // MARK: Layout
    
    private func setupLayout() {
        tableView.pin(to: view)
    }
    
    // MARK: - Updating
    
    private func startObservingChanges() {
        // Start observing for data changes
        dataChangeObservable = Storage.shared.start(
            viewModel.observableViewData,
            onError:  { _ in },
            onChange: { [weak self] viewData in
                // The defaul scheduler emits changes on the main thread
                self?.handleUpdates(viewData)
            }
        )
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
            .receiveOnMain(immediately: true)
            .sinkUntilComplete(
                receiveValue: { [weak self] attachments in
                    guard let strongSelf = self else { return }
                    
                    let approvalVC: UINavigationController = AttachmentApprovalViewController.wrappedInNavController(
                        threadId: strongSelf.viewModel.viewData[indexPath.row].threadId,
                        attachments: attachments,
                        approvalDelegate: strongSelf
                    )
                    strongSelf.navigationController?.present(approvalVC, animated: true, completion: nil)
                }
            )
    }
    
    func attachmentApproval(_ attachmentApproval: AttachmentApprovalViewController, didApproveAttachments attachments: [SignalAttachment], forThreadId threadId: String, messageText: String?) {
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
                    "\(attachments[0].text() ?? "")\n\n\(messageText ?? "")"
                )
            ) :
            messageText
        )
        
        shareNavController?.dismiss(animated: true, completion: nil)
        
        ModalActivityIndicatorViewController.present(fromViewController: shareNavController!, canCancel: false, message: "vc_share_sending_message".localized()) { activityIndicator in
            // Resume database
            NotificationCenter.default.post(name: Database.resumeNotification, object: self)
            
            Storage.shared
                .writePublisher(receiveOn: DispatchQueue.global(qos: .userInitiated)) { db -> MessageSender.PreparedSendData in
                    guard let thread: SessionThread = try SessionThread.fetchOne(db, id: threadId) else {
                        throw MessageSenderError.noThread
                    }
                    
                    // Create the interaction
                    let interaction: Interaction = try Interaction(
                        threadId: threadId,
                        authorId: getUserHexEncodedPublicKey(db),
                        variant: .standardOutgoing,
                        body: body,
                        timestampMs: SnodeAPI.currentOffsetTimestampMs(),
                        hasMention: Interaction.isUserMentioned(db, threadId: threadId, body: body),
                        expiresInSeconds: try? DisappearingMessagesConfiguration
                            .select(.durationSeconds)
                            .filter(id: threadId)
                            .filter(DisappearingMessagesConfiguration.Columns.isEnabled == true)
                            .asRequest(of: TimeInterval.self)
                            .fetchOne(db),
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
                            attachmentId: LinkPreview.saveAttachmentIfPossible(
                                db,
                                imageData: linkPreviewDraft.jpegImageData,
                                mimeType: OWSMimeTypeImageJpeg
                            )
                        ).insert(db)
                    }
                    
                    // Prepare any attachments
                    try Attachment.prepare(
                        db,
                        attachments: finalAttachments,
                        for: interactionId
                    )
                    
                    // Prepare the message send data
                    return try MessageSender
                        .preparedSendData(
                            db,
                            interaction: interaction,
                            in: thread
                        )
                }
                .flatMap {
                    MessageSender.performUploadsIfNeeded(
                        queue: DispatchQueue.global(qos: .userInitiated),
                        preparedSendData: $0
                    )
                }
                .flatMap { MessageSender.sendImmediate(preparedSendData: $0) }
                .receive(on: DispatchQueue.main)
                .sinkUntilComplete(
                    receiveCompletion: { [weak self] result in
                        // Suspend the database
                        NotificationCenter.default.post(name: Database.suspendNotification, object: self)
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
