// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import AVKit
import AVFoundation
import Combine
import CoreServices
import Photos
import PhotosUI
import UniformTypeIdentifiers
import GRDB
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit
import SignalUtilitiesKit
import SwiftUI
import SessionNetworkingKit

extension ConversationVC:
    InputViewDelegate,
    MessageCellDelegate,
    ContextMenuActionDelegate,
    SendMediaNavDelegate,
    AttachmentApprovalViewControllerDelegate,
    GifPickerViewControllerDelegate,
    UIGestureRecognizerDelegate
{
    // MARK: - Open Settings
    
    @MainActor @objc func handleTitleViewTapped() {
        // Don't take the user to settings for unapproved threads
        guard viewModel.threadData.threadRequiresApproval == false else { return }

        openSettingsFromTitleView()
    }
    
    // Handle taps outside of tableview cell to dismiss keyboard
    @MainActor @objc func dismissKeyboardOnTap() {
        _ = self.snInputView.resignFirstResponder()
    }
    
    @MainActor func openSettingsFromTitleView() {
        // If we shouldn't be able to access settings then disable the title view shortcuts
        guard viewModel.threadData.canAccessSettings(using: viewModel.dependencies) else { return }
        
        switch (titleView.currentLabelType, viewModel.threadData.threadVariant, viewModel.threadData.currentUserIsClosedGroupMember, viewModel.threadData.currentUserIsClosedGroupAdmin) {
            case (.userCount, .group, _, true), (.userCount, .legacyGroup, _, true):
                let viewController = SessionTableViewController(
                    viewModel: EditGroupViewModel(
                        threadId: self.viewModel.threadData.threadId,
                        using: self.viewModel.dependencies
                    )
                )
                navigationController?.pushViewController(viewController, animated: true)
                
            case (.userCount, .group, true, _), (.userCount, .legacyGroup, true, _):
                let viewController: UIViewController = ThreadSettingsViewModel.createMemberListViewController(
                    threadId: self.viewModel.threadData.threadId,
                    transitionToConversation: { [weak self, dependencies = viewModel.dependencies] selectedMemberId in
                        self?.navigationController?.pushViewController(
                            ConversationVC(
                                threadId: selectedMemberId,
                                threadVariant: .contact,
                                using: dependencies
                            ),
                            animated: true
                        )
                    },
                    using: viewModel.dependencies
                )
                navigationController?.pushViewController(viewController, animated: true)
                
            case (.disappearingMessageSetting, _, _, _):
                guard let config: DisappearingMessagesConfiguration = self.viewModel.threadData.disappearingMessagesConfiguration else {
                    return openSettings()
                }
                
                let viewController = SessionTableViewController(
                    viewModel: ThreadDisappearingMessagesSettingsViewModel(
                        threadId: self.viewModel.threadData.threadId,
                        threadVariant: self.viewModel.threadData.threadVariant,
                        currentUserIsClosedGroupMember: self.viewModel.threadData.currentUserIsClosedGroupMember,
                        currentUserIsClosedGroupAdmin: self.viewModel.threadData.currentUserIsClosedGroupAdmin,
                        config: config,
                        using: self.viewModel.dependencies
                    )
                )
                navigationController?.pushViewController(viewController, animated: true)
                
            case (.userCount, _, _, _), (.none, _, _, _), (.notificationSettings, _, _, _): openSettings()
        }
    }

    @objc func openSettings() {
        let viewController = SessionTableViewController(viewModel: ThreadSettingsViewModel(
                threadId: self.viewModel.threadData.threadId,
                threadVariant: self.viewModel.threadData.threadVariant,
                didTriggerSearch: { [weak self] in
                    DispatchQueue.main.async {
                        self?.showSearchUI()
                        self?.popAllConversationSettingsViews {
                            // Note: Without this delay the search bar doesn't show
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                self?.searchController.uiSearchController.searchBar.becomeFirstResponder()
                            }
                        }
                    }
                },
                using: self.viewModel.dependencies
            )
        )
        navigationController?.pushViewController(viewController, animated: true)
    }
    
    // MARK: - External keyboard
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key else { continue }

            if key.keyCode == .keyboardReturnOrEnter && key.modifierFlags.isEmpty {
                // Enter only -> send
                handleSendButtonTapped()
                return
            }
        }
        super.pressesBegan(presses, with: event)
    }
    
    // MARK: - Call
    
    @objc func startCall(_ sender: Any?) {
        guard viewModel.threadData.threadIsBlocked != true else {
            self.showBlockedModalIfNeeded()
            return
        }
        guard viewModel.dependencies.mutate(cache: .libSession, { $0.get(.areCallsEnabled) }) else {
            let confirmationModal: ConfirmationModal = ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: "callsPermissionsRequired".localized(),
                    body: .text("callsPermissionsRequiredDescription".localized()),
                    confirmTitle: "sessionSettings".localized(),
                    dismissOnConfirm: false // Custom dismissal logic
                ) { [weak self, dependencies = viewModel.dependencies] _ in
                    self?.dismiss(animated: true) {
                        let navController: UINavigationController = StyledNavigationController(
                            rootViewController: SessionTableViewController(
                                viewModel: PrivacySettingsViewModel(
                                    shouldShowCloseButton: true,
                                    shouldAutomaticallyShowCallModal: true,
                                    using: dependencies
                                )
                            )
                        )
                        navController.modalPresentationStyle = .fullScreen
                        self?.present(navController, animated: true, completion: nil)
                    }
                }
            )
            
            self.navigationController?.present(confirmationModal, animated: true, completion: nil)
            return
        }
        
        guard Permissions.microphone == .granted else {
            let confirmationModal: ConfirmationModal = ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: "permissionsRequired".localized(),
                    body: .text("permissionsMicrophoneAccessRequiredCallsIos".localized()),
                    showCondition: .disabled,
                    confirmTitle: "sessionSettings".localized(),
                    onConfirm: { _ in
                        UIApplication.shared.openSystemSettings()
                    }
                )
            )
            
            self.navigationController?.present(confirmationModal, animated: true, completion: nil)
            return
        }
        
        guard Permissions.localNetwork(using: viewModel.dependencies) == .granted else {
            let confirmationModal: ConfirmationModal = ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: "permissionsRequired".localized(),
                    body: .text("permissionsLocalNetworkAccessRequiredCallsIos".localized()),
                    showCondition: .disabled,
                    confirmTitle: "sessionSettings".localized(),
                    onConfirm: { _ in
                        UIApplication.shared.openSystemSettings()
                    }
                )
            )
            
            self.navigationController?.present(confirmationModal, animated: true, completion: nil)
            return
        }
        
        let threadId: String = self.viewModel.threadData.threadId
        
        guard
            Permissions.microphone == .granted,
            self.viewModel.threadData.threadVariant == .contact,
            viewModel.dependencies[singleton: .callManager].currentCall == nil
        else { return }
        
        let call: SessionCall = SessionCall(
            for: threadId,
            contactName: self.viewModel.threadData.displayName,
            uuid: UUID().uuidString.lowercased(),
            mode: .offer,
            using: viewModel.dependencies
        )
        let callVC = CallVC(for: call, using: viewModel.dependencies)
        callVC.conversationVC = self
        hideInputAccessoryView()
        resignFirstResponder()
        
        present(callVC, animated: true, completion: nil)
    }

    // MARK: - Blocking
    
    @discardableResult func showBlockedModalIfNeeded() -> Bool {
        guard
            self.viewModel.threadData.threadVariant == .contact &&
            self.viewModel.threadData.threadIsBlocked == true
        else { return false }
        
        let confirmationModal: ConfirmationModal = ConfirmationModal(
            info: ConfirmationModal.Info(
                title: String(
                    format: "blockUnblock".localized(),
                    self.viewModel.threadData.displayName
                ),
                body: .attributedText(
                    "blockUnblockName"
                        .put(key: "name", value: viewModel.threadData.displayName)
                        .localizedFormatted(baseFont: .systemFont(ofSize: Values.smallFontSize))
                ),
                confirmTitle: "blockUnblock".localized(),
                confirmStyle: .danger,
                cancelStyle: .alert_text,
                dismissOnConfirm: false // Custom dismissal logic
            ) { [weak self] _ in
                self?.viewModel.unblockContact()
                self?.dismiss(animated: true, completion: nil)
            }
        )
        present(confirmationModal, animated: true, completion: nil)
        
        return true
    }
    
    // MARK: - Session Pro CTA
    
    @discardableResult func showSessionProCTAIfNeeded() -> Bool {
        let dependencies: Dependencies = viewModel.dependencies
        guard dependencies[feature: .sessionProEnabled] && (!viewModel.isSessionPro) else {
            return false
        }
        self.hideInputAccessoryView()
        let sessionProModal: ModalHostingViewController = ModalHostingViewController(
            modal: ProCTAModal(
                delegate: dependencies[singleton: .sessionProState],
                variant: .longerMessages,
                dataManager: viewModel.dependencies[singleton: .imageDataManager],
                afterClosed: { [weak self] in
                    self?.showInputAccessoryView()
                    self?.snInputView.updateNumberOfCharactersLeft(self?.snInputView.text ?? "")
                }
            )
        )
        present(sessionProModal, animated: true, completion: nil)
        
        return true
    }
    
    // MARK: - UIGestureRecognizerDelegate
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }

    // MARK: - SendMediaNavDelegate

    func sendMediaNavDidCancel(_ sendMediaNavigationController: SendMediaNavigationController?) {
        dismiss(animated: true, completion: nil)
    }

    func sendMediaNav(
        _ sendMediaNavigationController: SendMediaNavigationController,
        didApproveAttachments attachments: [SignalAttachment],
        forThreadId threadId: String,
        threadVariant: SessionThread.Variant,
        messageText: String?
    ) {
        sendMessage(text: (messageText ?? ""), attachments: attachments)
        resetMentions()
        
        dismiss(animated: true) { [weak self] in
            if self?.isFirstResponder == false {
                self?.becomeFirstResponder()
            }
            else {
                self?.reloadInputViews()
            }
        }
    }

    func sendMediaNavInitialMessageText(_ sendMediaNavigationController: SendMediaNavigationController) -> String? {
        return snInputView.text
    }

    func sendMediaNav(_ sendMediaNavigationController: SendMediaNavigationController, didChangeMessageText newMessageText: String?) {
        snInputView.text = (newMessageText ?? "")
    }

    // MARK: - AttachmentApprovalViewControllerDelegate
    
    func attachmentApproval(
        _ attachmentApproval: AttachmentApprovalViewController,
        didApproveAttachments attachments: [SignalAttachment],
        forThreadId threadId: String,
        threadVariant: SessionThread.Variant,
        messageText: String?
    ) {
        sendMessage(text: (messageText ?? ""), attachments: attachments)
        resetMentions()
        
        dismiss(animated: true) { [weak self] in
            if self?.isFirstResponder == false {
                self?.becomeFirstResponder()
            }
            else {
                self?.reloadInputViews()
            }
        }
    }

    func attachmentApprovalDidCancel(_ attachmentApproval: AttachmentApprovalViewController) {
        dismiss(animated: true, completion: nil)
    }

    func attachmentApproval(_ attachmentApproval: AttachmentApprovalViewController, didChangeMessageText newMessageText: String?) {
        snInputView.text = (newMessageText ?? "")
    }
    
    func attachmentApproval(_ attachmentApproval: AttachmentApprovalViewController, didRemoveAttachment attachment: SignalAttachment) {
    }

    func attachmentApprovalDidTapAddMore(_ attachmentApproval: AttachmentApprovalViewController) {
    }

    // MARK: - ExpandingAttachmentsButtonDelegate

    func handleGIFButtonTapped() {
        guard viewModel.dependencies.mutate(cache: .libSession, { $0.get(.isGiphyEnabled) }) else {
            let modal: ConfirmationModal = ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: "giphyWarning".localized(),
                    body: .text(
                        "giphyWarningDescription"
                            .put(key: "app_name", value: Constants.app_name)
                            .localized()
                    ),
                    confirmTitle: "theContinue".localized()
                ) { [weak self, dependencies = viewModel.dependencies] _ in
                    dependencies.setAsync(.isGiphyEnabled, true) {
                        self?.handleGIFButtonTapped()
                    }
                }
            )
            
            present(modal, animated: true, completion: nil)
            return
        }
        
        let gifVC = GifPickerViewController(using: viewModel.dependencies)
        gifVC.delegate = self
        
        let navController = StyledNavigationController(rootViewController: gifVC)
        navController.modalPresentationStyle = .fullScreen
        present(navController, animated: true) { }
    }

    func handleDocumentButtonTapped() {
        // UIDocumentPickerModeImport copies to a temp file within our container.
        // It uses more memory than "open" but lets us avoid working with security scoped URLs.
        let documentPickerVC = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        documentPickerVC.modalPresentationStyle = .fullScreen
        
        self.documentHandler = DocumentPickerHandler(
            didPickDocumentsAt: { [weak self, dependencies = viewModel.dependencies] _, urls in
                defer {
                    self?.showInputAccessoryView()
                    self?.becomeFirstResponder()
                    self?.documentHandler = nil
                }
                
                guard let url: URL = urls.first else { return }
                
                let urlResourceValues: URLResourceValues
                do {
                    urlResourceValues = try url.resourceValues(forKeys: [ .typeIdentifierKey, .isDirectoryKey, .nameKey ])
                }
                catch {
                    DispatchQueue.main.async { [weak self] in
                        self?.viewModel.showToast(text: "attachmentsErrorLoad".localized())
                    }
                    return
                }
                
                let type: UTType = (urlResourceValues.typeIdentifier.map({ UTType($0) }) ?? .data)
                guard urlResourceValues.isDirectory != true else {
                    DispatchQueue.main.async { [weak self] in
                        let modal: ConfirmationModal = ConfirmationModal(
                            targetView: self?.view,
                            info: ConfirmationModal.Info(
                                title: "attachmentsErrorLoad".localized(),
                                body: .text("attachmentsErrorNotSupported".localized()),
                                cancelTitle: "okay".localized(),
                                cancelStyle: .alert_text
                            )
                        )
                        self?.present(modal, animated: true)
                    }
                    return
                }
                
                let fileName: String = (urlResourceValues.name ?? "attachment".localized())
                guard let dataSource = DataSourcePath(fileUrl: url, sourceFilename: urlResourceValues.name, shouldDeleteOnDeinit: false, using: dependencies) else {
                    DispatchQueue.main.async { [weak self] in
                        self?.viewModel.showToast(text: "attachmentsErrorLoad".localized())
                    }
                    return
                }
                dataSource.sourceFilename = fileName
                
                // Although we want to be able to send higher quality attachments through the document picker
                // it's more imporant that we ensure the sent format is one all clients can accept (e.g. *not* quicktime .mov)
                guard !SignalAttachment.isInvalidVideo(dataSource: dataSource, type: type) else {
                    self?.showAttachmentApprovalDialogAfterProcessingVideo(at: url, with: fileName)
                    return
                }
                
                // "Document picker" attachments _SHOULD NOT_ be resized
                let attachment = SignalAttachment.attachment(dataSource: dataSource, type: type, imageQuality: .original, using: dependencies)
                self?.showAttachmentApprovalDialog(for: [ attachment ])
            },
            wasCancelled: { [weak self] _ in
                self?.showInputAccessoryView()
                self?.becomeFirstResponder()
                self?.documentHandler = nil
            }
        )
        documentPickerVC.delegate = self.documentHandler
        
        present(documentPickerVC, animated: true, completion: nil)
    }
    
    func handleLibraryButtonTapped() {
        let threadId: String = self.viewModel.threadData.threadId
        let threadVariant: SessionThread.Variant = self.viewModel.threadData.threadVariant
        
        Permissions.requestLibraryPermissionIfNeeded(isSavingMedia: false, using: viewModel.dependencies) { [weak self, dependencies = viewModel.dependencies] in
            DispatchQueue.main.async {
                let sendMediaNavController = SendMediaNavigationController.showingMediaLibraryFirst(
                    threadId: threadId,
                    threadVariant: threadVariant,
                    using: dependencies
                )
                sendMediaNavController.sendMediaNavDelegate = self
                sendMediaNavController.modalPresentationStyle = .fullScreen
                self?.present(sendMediaNavController, animated: true, completion: nil)
            }
        }
    }
    
    func handleCameraButtonTapped() {
        guard Permissions.requestCameraPermissionIfNeeded(presentingViewController: self, using: viewModel.dependencies) else { return }
        
        Permissions.requestMicrophonePermissionIfNeeded(using: viewModel.dependencies)
        
        if Permissions.microphone != .granted {
            Log.warn(.conversation, "Proceeding without microphone access. Any recorded video will be silent.")
        }
        
        let sendMediaNavController = SendMediaNavigationController.showingCameraFirst(
            threadId: self.viewModel.threadData.threadId,
            threadVariant: self.viewModel.threadData.threadVariant,
            using: self.viewModel.dependencies
        )
        sendMediaNavController.sendMediaNavDelegate = self
        sendMediaNavController.modalPresentationStyle = .fullScreen
        
        present(sendMediaNavController, animated: true, completion: nil)
    }
    
    // MARK: - GifPickerViewControllerDelegate
    
    func gifPickerDidSelect(attachment: SignalAttachment) {
        showAttachmentApprovalDialog(for: [ attachment ])
    }
    
    func showAttachmentApprovalDialog(for attachments: [SignalAttachment]) {
        guard let navController = AttachmentApprovalViewController.wrappedInNavController(
            threadId: self.viewModel.threadData.threadId,
            threadVariant: self.viewModel.threadData.threadVariant,
            attachments: attachments,
            approvalDelegate: self,
            disableLinkPreviewImageDownload: (self.viewModel.threadData.threadCanUpload != true),
            using: self.viewModel.dependencies
        ) else { return }
        navController.modalPresentationStyle = .fullScreen
        
        present(navController, animated: true, completion: nil)
    }

    func showAttachmentApprovalDialogAfterProcessingVideo(at url: URL, with fileName: String) {
        ModalActivityIndicatorViewController.present(fromViewController: self, canCancel: true, message: nil) { [weak self, dependencies = viewModel.dependencies] modalActivityIndicator in
            
            guard let dataSource = DataSourcePath(fileUrl: url, sourceFilename: fileName, shouldDeleteOnDeinit: false, using: dependencies) else {
                self?.showErrorAlert(for: SignalAttachment.empty(using: dependencies))
                return
            }
            dataSource.sourceFilename = fileName
            
            SignalAttachment
                .compressVideoAsMp4(
                    dataSource: dataSource,
                    type: .mpeg4Movie,
                    using: dependencies
                )
                .attachmentPublisher
                .sinkUntilComplete(
                    receiveValue: { [weak self] attachment in
                        guard !modalActivityIndicator.wasCancelled else { return }
                        
                        modalActivityIndicator.dismiss {
                            guard !attachment.hasError else {
                                self?.showErrorAlert(for: attachment)
                                return
                            }
                            
                            self?.showAttachmentApprovalDialog(for: [ attachment ])
                        }
                    }
                )
        }
    }
    
    // MARK: - InputViewDelegate
    
    func handleDisabledInputTapped() {
        guard viewModel.threadData.threadIsBlocked == true else { return }
        
        self.showBlockedModalIfNeeded()
    }
    
    func handleCharacterLimitLabelTapped() {
        guard !showSessionProCTAIfNeeded() else { return }
        
        self.hideInputAccessoryView()
        let numberOfCharactersLeft: Int = LibSession.numberOfCharactersLeft(
            for: snInputView.text.trimmingCharacters(in: .whitespacesAndNewlines),
            isSessionPro: viewModel.isSessionPro
        )
        let limit: Int = (viewModel.isSessionPro ? LibSession.ProCharacterLimit : LibSession.CharacterLimit)
        
        let confirmationModal: ConfirmationModal = ConfirmationModal(
            info: ConfirmationModal.Info(
                title: (
                    (numberOfCharactersLeft >= 0) ?
                        "modalMessageCharacterDisplayTitle".localized() :
                        "modalMessageCharacterTooLongTitle".localized()
                ),
                body: .text(
                    (
                        (numberOfCharactersLeft >= 0) ?
                            "modalMessageCharacterDisplayDescription"
                                .putNumber(numberOfCharactersLeft)
                                .put(key: "limit", value: limit)
                                .localized() :
                            "modalMessageCharacterTooLongDescription"
                                .put(key: "limit", value: limit)
                                .localized()
                    ),
                    scrollMode: .never
                ),
                cancelTitle: "okay".localized(),
                cancelStyle: .alert_text,
                afterClosed: { [weak self] in
                    self?.showInputAccessoryView()
                }
            )
        )
        present(confirmationModal, animated: true, completion: nil)
    }
    
    func handleDisabledAttachmentButtonTapped() {
        /// This logic was added because an Apple reviewer rejected an emergency update as they thought these buttons were
        /// unresponsive (even though there is copy on the screen communicating that they are intentionally disabled) - in order
        /// to prevent this happening in the future we've added this toast when pressing on the disabled button
        guard viewModel.threadData.threadIsMessageRequest == true else { return }
        
        let toastController: ToastController = ToastController(
            text: "messageRequestDisabledToastAttachments".localized(),
            background: .backgroundSecondary
        )
        toastController.presentToastView(
            fromBottomOfView: self.view,
            inset: (snInputView.bounds.height + Values.largeSpacing),
            duration: .milliseconds(2500)
        )
    }
    
    func handleDisabledVoiceMessageButtonTapped() {
        /// This logic was added because an Apple reviewer rejected an emergency update as they thought these buttons were
        /// unresponsive (even though there is copy on the screen communicating that they are intentionally disabled) - in order
        /// to prevent this happening in the future we've added this toast when pressing on the disabled button
        guard viewModel.threadData.threadIsMessageRequest == true else { return }
        
        let toastController: ToastController = ToastController(
            text: "messageRequestDisabledToastVoiceMessages".localized(),
            background: .backgroundSecondary
        )
        toastController.presentToastView(
            fromBottomOfView: self.view,
            inset: (snInputView.bounds.height + Values.largeSpacing),
            duration: .milliseconds(2500)
        )
    }

    // MARK: --Message Sending
    
    func handleSendButtonTapped() {
        guard LibSession.numberOfCharactersLeft(
            for: snInputView.text.trimmingCharacters(in: .whitespacesAndNewlines),
            isSessionPro: viewModel.isSessionPro
        ) >= 0 else {
            showModalForMessagesExceedingCharacterLimit(isSessionPro: viewModel.isSessionPro)
            return
        }
        
        sendMessage(
            text: snInputView.text.trimmingCharacters(in: .whitespacesAndNewlines),
            linkPreviewDraft: snInputView.linkPreviewInfo?.draft,
            quoteModel: snInputView.quoteDraftInfo?.model
        )
    }
    
    func showModalForMessagesExceedingCharacterLimit(isSessionPro: Bool) {
        guard !showSessionProCTAIfNeeded() else { return }
        
        self.hideInputAccessoryView()
        let confirmationModal: ConfirmationModal = ConfirmationModal(
            info: ConfirmationModal.Info(
                title: "modalMessageCharacterTooLongTitle".localized(),
                body: .text(
                    "modalMessageTooLongDescription"
                        .put(key: "limit", value: (isSessionPro ? LibSession.ProCharacterLimit : LibSession.CharacterLimit))
                        .localized(),
                    scrollMode: .never
                ),
                cancelTitle: "okay".localized(),
                cancelStyle: .alert_text,
                afterClosed: { [weak self] in
                    self?.showInputAccessoryView()
                }
            )
        )
        present(confirmationModal, animated: true, completion: nil)
    }

    func sendMessage(
        text: String,
        attachments: [SignalAttachment] = [],
        linkPreviewDraft: LinkPreviewDraft? = nil,
        quoteModel: QuotedReplyModel? = nil,
        hasPermissionToSendSeed: Bool = false
    ) {
        guard !showBlockedModalIfNeeded() else { return }
        
        // Handle attachment errors if applicable
        if let failedAttachment: SignalAttachment = attachments.first(where: { $0.hasError }) {
            return showErrorAlert(for: failedAttachment)
        }
        
        let processedText: String = replaceMentions(in: text.trimmingCharacters(in: .whitespacesAndNewlines))
        
        // If we have no content then do nothing
        guard !processedText.isEmpty || !attachments.isEmpty else { return }

        if processedText.contains(mnemonic) && !viewModel.threadData.threadIsNoteToSelf && !hasPermissionToSendSeed {
            // Warn the user if they're about to send their seed to someone
            let modal: ConfirmationModal = ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: "warning".localized(),
                    body: .text("recoveryPasswordWarningSendDescription".localized()),
                    confirmTitle: "send".localized(),
                    confirmStyle: .danger,
                    cancelStyle: .alert_text,
                    onConfirm: { [weak self] _ in
                        self?.sendMessage(
                            text: text,
                            attachments: attachments,
                            linkPreviewDraft: linkPreviewDraft,
                            quoteModel: quoteModel,
                            hasPermissionToSendSeed: true
                        )
                    }
                )
            )
            
            return present(modal, animated: true, completion: nil)
        }
        
        // Clearing this out immediately to make this appear more snappy
        DispatchQueue.main.async { [weak self] in
            self?.snInputView.text = ""
            self?.snInputView.quoteDraftInfo = nil

            self?.resetMentions()
            self?.scrollToBottom(isAnimated: false)
        }

        // Optimistically insert the outgoing message (this will trigger a UI update)
        self.viewModel.sentMessageBeforeUpdate = true
        let sentTimestampMs: Int64 = viewModel.dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
        let optimisticData: ConversationViewModel.OptimisticMessageData = self.viewModel.optimisticallyAppendOutgoingMessage(
            text: processedText,
            sentTimestampMs: sentTimestampMs,
            attachments: attachments,
            linkPreviewDraft: linkPreviewDraft,
            quoteModel: quoteModel
        )
        
        // If this was a message request then approve it
        approveMessageRequestIfNeeded(
            for: self.viewModel.threadData.threadId,
            threadVariant: self.viewModel.threadData.threadVariant,
            displayName: self.viewModel.threadData.displayName,
            isDraft: (self.viewModel.threadData.threadIsDraft == true),
            timestampMs: (sentTimestampMs - 1)  // Set 1ms earlier as this is used for sorting
        ).sinkUntilComplete(
            receiveCompletion: { [weak self] _ in
                self?.sendMessage(optimisticData: optimisticData)
            }
        )
    }
    
    private func sendMessage(optimisticData: ConversationViewModel.OptimisticMessageData) {
        let threadId: String = self.viewModel.threadData.threadId
        let threadVariant: SessionThread.Variant = self.viewModel.threadData.threadVariant
        
        // Actually send the message
        viewModel.dependencies[singleton: .storage]
            .writePublisher { [weak self, dependencies = viewModel.dependencies] db in
                // Update the thread to be visible (if it isn't already)
                if self?.viewModel.threadData.threadShouldBeVisible == false {
                    try SessionThread.updateVisibility(
                        db,
                        threadId: threadId,
                        isVisible: true,
                        additionalChanges: [SessionThread.Columns.isDraft.set(to: false)],
                        using: dependencies
                    )
                }
                
                // Insert the interaction and associated it with the optimistically inserted message so
                // we can remove it once the database triggers a UI update
                let insertedInteraction: Interaction = try optimisticData.interaction.inserted(db)
                self?.viewModel.associate(optimisticMessageId: optimisticData.id, to: insertedInteraction.id)
                
                // If there is a LinkPreview draft then check the state of any existing link previews and
                // insert a new one if needed
                if let linkPreviewDraft: LinkPreviewDraft = optimisticData.linkPreviewDraft {
                    let invalidLinkPreviewAttachmentStates: [Attachment.State] = [
                        .failedDownload, .pendingDownload, .downloading, .failedUpload, .invalid
                    ]
                    let linkPreviewAttachmentId: String? = try? insertedInteraction.linkPreview
                        .select(.attachmentId)
                        .asRequest(of: String.self)
                        .fetchOne(db)
                    let linkPreviewAttachmentState: Attachment.State = linkPreviewAttachmentId
                        .map {
                            try? Attachment
                                .filter(id: $0)
                                .select(.state)
                                .asRequest(of: Attachment.State.self)
                                .fetchOne(db)
                        }
                        .defaulting(to: .invalid)
                    
                    // If we don't have a "valid" existing link preview then upsert a new one
                    if invalidLinkPreviewAttachmentStates.contains(linkPreviewAttachmentState) {
                        try LinkPreview(
                            url: linkPreviewDraft.urlString,
                            title: linkPreviewDraft.title,
                            attachmentId: try optimisticData.linkPreviewAttachment?.inserted(db).id,
                            using: dependencies
                        ).upsert(db)
                    }
                }
                
                // If there is a Quote the insert it now
                if let interactionId: Int64 = insertedInteraction.id, let quoteModel: QuotedReplyModel = optimisticData.quoteModel {
                    try Quote(
                        interactionId: interactionId,
                        authorId: quoteModel.authorId,
                        timestampMs: quoteModel.timestampMs,
                        body: nil
                    ).insert(db)
                }
                
                // Process any attachments
                try AttachmentUploader.process(
                    db,
                    attachments: optimisticData.attachmentData,
                    for: insertedInteraction.id
                )
                
                // If we are sending a blinded message then we need to update the blinded profile
                // information to ensure the name is up to date (as it won't be updated otherwise
                // because the message would get deduped when fetched from the poller)
                // FIXME: Remove this once we don't generate unique Profile entries for the current users blinded ids
                if (try? SessionId.Prefix(from: optimisticData.interaction.authorId)) != .standard {
                    let currentUserProfile: Profile = dependencies.mutate(cache: .libSession) { $0.profile }
                    
                    try? Profile.updateIfNeeded(
                        db,
                        publicKey: optimisticData.interaction.authorId,
                        displayNameUpdate: .contactUpdate(currentUserProfile.name),
                        displayPictureUpdate: DisplayPictureManager.Update.from(
                            currentUserProfile,
                            fallback: .none,
                            using: dependencies
                        ),
                        sentTimestamp: (Double(optimisticData.interaction.timestampMs) / 1000),
                        using: dependencies
                    )
                }
                
                try MessageSender.send(
                    db,
                    interaction: insertedInteraction,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    using: dependencies
                )
            }
            .subscribe(on: DispatchQueue.global(qos: .userInitiated))
            .sinkUntilComplete(
                receiveCompletion: { [weak self] result in
                    switch result {
                        case .finished: break
                        case .failure(let error):
                            self?.viewModel.failedToStoreOptimisticOutgoingMessage(id: optimisticData.id, error: error)
                    }
                    
                    self?.handleMessageSent()
                }
            )
    }

    func handleMessageSent() {
        if viewModel.dependencies.mutate(cache: .libSession, { $0.get(.playNotificationSoundInForeground) }) {
            let soundID = Preferences.Sound.systemSoundId(for: .messageSent, quiet: true)
            AudioServicesPlaySystemSound(soundID)
        }
        
        let threadId: String = self.viewModel.threadData.threadId
        
        Task {
            await viewModel.dependencies[singleton: .typingIndicators].didStopTyping(
                threadId: threadId,
                direction: .outgoing
            )
        }
        
        viewModel.dependencies[singleton: .storage].writeAsync { db in
            _ = try SessionThread
                .filter(id: threadId)
                .updateAll(db, SessionThread.Columns.messageDraft.set(to: ""))
        }
    }

    func showLinkPreviewSuggestionModal() {
        // Hides accessory view while link preview confirmation is presented
        hideInputAccessoryView()
        
        let linkPreviewModal: ConfirmationModal = ConfirmationModal(
            info: ConfirmationModal.Info(
                title: "linkPreviewsEnable".localized(),
                body: .text(
                    "linkPreviewsFirstDescription"
                        .put(key: "app_name", value: Constants.app_name)
                        .localized()
                ),
                confirmTitle: "enable".localized(),
                confirmStyle: .danger,
                cancelStyle: .alert_text,
                onConfirm: { [weak self, dependencies = viewModel.dependencies] _ in
                    dependencies.setAsync(.areLinkPreviewsEnabled, true) {
                        self?.snInputView.autoGenerateLinkPreview()
                    }
                },
                afterClosed: { [weak self] in
                    // Bring back accessory view after confirmation action
                    self?.showInputAccessoryView()
                }
            )
        )
        
        present(linkPreviewModal, animated: true, completion: nil)
    }
    
    func inputTextViewDidChangeContent(_ inputTextView: InputTextView) {
        // Note: If there is a 'draft' message then we don't want it to trigger the typing indicator to
        // appear (as that is not expected/correct behaviour)
        guard !viewIsAppearing else { return }
        
        let newText: String = (inputTextView.text ?? "")
        
        if !newText.isEmpty {
            Task { [threadData = viewModel.threadData, dependencies = viewModel.dependencies] in
                await viewModel.dependencies[singleton: .typingIndicators].startIfNeeded(
                    threadId: threadData.threadId,
                    threadVariant: threadData.threadVariant,
                    direction: .outgoing,
                    timestampMs: dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
                )
            }
        }
        
        updateMentions(for: newText)
        // Note: When calculating the number of characters left, we need to use the original mention
        // text which contains the session id rather than display name.
        snInputView.updateNumberOfCharactersLeft(replaceMentions(in: newText))
    }
    
    // MARK: --Attachments
    
    func didPasteImageFromPasteboard(_ image: UIImage) {
        guard let imageData = image.jpegData(compressionQuality: 1.0) else { return }
        
        let dataSource = DataSourceValue(data: imageData, dataType: .jpeg, using: viewModel.dependencies)
        let attachment = SignalAttachment.attachment(dataSource: dataSource, type: .jpeg, imageQuality: .medium, using: viewModel.dependencies)

        guard let approvalVC = AttachmentApprovalViewController.wrappedInNavController(
            threadId: self.viewModel.threadData.threadId,
            threadVariant: self.viewModel.threadData.threadVariant,
            attachments: [ attachment ],
            approvalDelegate: self,
            disableLinkPreviewImageDownload: (self.viewModel.threadData.threadCanUpload != true),
            using: self.viewModel.dependencies
        ) else { return }
        approvalVC.modalPresentationStyle = .fullScreen
        
        self.present(approvalVC, animated: true, completion: nil)
    }

    // MARK: --Mentions
    
    func handleMentionSelected(_ mentionInfo: MentionInfo, from view: MentionSelectionView) {
        guard let currentMentionStartIndex = currentMentionStartIndex else { return }
        
        mentions.append(mentionInfo)
        
        let displayNameForMention: String = mentionInfo.profile.displayNameForMention(
            for: self.viewModel.threadData.threadVariant,
            currentUserSessionIds: (self.viewModel.threadData.currentUserSessionIds ?? [])
        )
        
        let newText: String = snInputView.text.replacingCharacters(
            in: currentMentionStartIndex...,
            with: "@\(displayNameForMention) " // stringlint:ignore
        )
        
        snInputView.text = newText
        self.currentMentionStartIndex = nil
        snInputView.hideMentionsUI()
        
        mentions = mentions.filter { mentionInfo -> Bool in
            newText.contains(
                mentionInfo.profile.displayNameForMention(
                    for: self.viewModel.threadData.threadVariant,
                    currentUserSessionIds: (self.viewModel.threadData.currentUserSessionIds ?? [])
                )
            )
        }
    }
    
    func updateMentions(for newText: String) {
        guard !newText.isEmpty else {
            if currentMentionStartIndex != nil {
                snInputView.hideMentionsUI()
            }
            
            resetMentions()
            return
        }
        
        let lastCharacterIndex = newText.index(before: newText.endIndex)
        let lastCharacter = newText[lastCharacterIndex]
        
        // Check if there is whitespace before the '@' or the '@' is the first character
        let isCharacterBeforeLastWhiteSpaceOrStartOfLine: Bool
        if newText.count == 1 {
            isCharacterBeforeLastWhiteSpaceOrStartOfLine = true // Start of line
        }
        else {
            let characterBeforeLast = newText[newText.index(before: lastCharacterIndex)]
            isCharacterBeforeLastWhiteSpaceOrStartOfLine = characterBeforeLast.isWhitespace
        }
        
        // stringlint:ignore_start
        if lastCharacter == "@" && isCharacterBeforeLastWhiteSpaceOrStartOfLine {
            currentMentionStartIndex = lastCharacterIndex
            snInputView.showMentionsUI(
                for: self.viewModel.mentions(),
                currentUserSessionIds: (self.viewModel.threadData.currentUserSessionIds ?? [])
            )
        }
        else if lastCharacter.isWhitespace || lastCharacter == "@" { // the lastCharacter == "@" is to check for @@
            currentMentionStartIndex = nil
            snInputView.hideMentionsUI()
        }
        else {
            if let currentMentionStartIndex = currentMentionStartIndex {
                let query = String(newText[newText.index(after: currentMentionStartIndex)...]) // + 1 to get rid of the @
                snInputView.showMentionsUI(
                    for: self.viewModel.mentions(for: query),
                    currentUserSessionIds: (self.viewModel.threadData.currentUserSessionIds ?? [])
                )
            }
        }
        // stringlint:ignore_stop
    }

    func resetMentions() {
        currentMentionStartIndex = nil
        mentions = []
    }

    // stringlint:ignore_contents
    func replaceMentions(in text: String) -> String {
        var result = text
        
        for mention in mentions {
            let displayNameForMention: String = mention.profile.displayNameForMention(
                for: mention.threadVariant,
                currentUserSessionIds: (self.viewModel.threadData.currentUserSessionIds ?? [])
            )
            guard let range = result.range(of: "@\(displayNameForMention)") else { continue }
            result = result.replacingCharacters(in: range, with: "@\(mention.profile.id)")
        }
        
        return result
    }
    
    func hideInputAccessoryView() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.hideInputAccessoryView()
            }
            return
        }
        self.isKeyboardVisible = self.snInputView.isInputFirstResponder
        self.inputAccessoryView?.resignFirstResponder()
        self.inputAccessoryView?.isHidden = true
        self.inputAccessoryView?.alpha = 0
    }
    
    func showInputAccessoryView() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.showInputAccessoryView()
            }
            return
        }
        UIView.animate(withDuration: 0.25, animations: {
            self.inputAccessoryView?.isHidden = false
            self.inputAccessoryView?.alpha = 1
            if self.isKeyboardVisible {
                self.inputAccessoryView?.becomeFirstResponder()
            }
        })
    }

    // MARK: MessageCellDelegate
    
    func handleItemLongPressed(_ cellViewModel: MessageViewModel) {
        // Show the unblock modal if needed
        guard self.viewModel.threadData.threadIsBlocked != true else {
            self.showBlockedModalIfNeeded()
            return
        }
        // Show the context menu if applicable
        guard
            // FIXME: Need to update this when an appropriate replacement is added (see https://teng.pub/technical/2021/11/9/uiapplication-key-window-replacement)
            let keyWindow: UIWindow = UIApplication.shared.keyWindow,
            let sectionIndex: Int = self.viewModel.interactionData
                .firstIndex(where: { $0.model == .messages }),
            let index = self.viewModel.interactionData[sectionIndex]
                .elements
                .firstIndex(of: cellViewModel),
            let cell = tableView.cellForRow(at: IndexPath(row: index, section: sectionIndex)) as? MessageCell,
            let contextSnapshotView: UIView = cell.contextSnapshotView,
            let snapshot = contextSnapshotView.snapshotView(afterScreenUpdates: false),
            contextMenuWindow == nil,
            let actions: [ContextMenuVC.Action] = ContextMenuVC.actions(
                for: cellViewModel,
                in: self.viewModel.threadData,
                forMessageInfoScreen: false,
                delegate: self,
                using: viewModel.dependencies
            )
        else { return }
        
        /// Lock the contentOffset of the tableView so the transition doesn't look buggy
        self.tableView.lockContentOffset = true
        
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        self.contextMenuWindow = ContextMenuWindow()
        self.contextMenuVC = ContextMenuVC(
            snapshot: snapshot,
            frame: contextSnapshotView.convert(contextSnapshotView.bounds, to: keyWindow),
            cellViewModel: cellViewModel,
            actions: actions,
            using: viewModel.dependencies
        ) { [weak self] in
            self?.contextMenuWindow?.isHidden = true
            self?.contextMenuVC = nil
            self?.contextMenuWindow = nil
            self?.scrollButton.alpha = 0
            
            UIView.animate(
                withDuration: 0.25,
                animations: { self?.updateScrollToBottom() },
                completion: { _ in
                    guard let contentOffset: CGPoint = self?.tableView.contentOffset else { return }
                    
                    // Unlock the contentOffset so everything will be in the right
                    // place when we return
                    self?.tableView.lockContentOffset = false
                    self?.tableView.setContentOffset(contentOffset, animated: false)
                }
            )
        }
        
        self.contextMenuWindow?.themeBackgroundColor = .clear
        self.contextMenuWindow?.rootViewController = self.contextMenuVC
        self.contextMenuWindow?.overrideUserInterfaceStyle = ThemeManager.currentTheme.interfaceStyle
        self.contextMenuWindow?.makeKeyAndVisible()
    }

    func handleItemTapped(
        _ cellViewModel: MessageViewModel,
        cell: UITableViewCell,
        cellLocation: CGPoint
    ) {
        // For call info messages show the "call missed" modal
        guard cellViewModel.variant != .infoCall else {
            // If the failure was due to the mic permission being denied then we want to show the permission modal,
            // otherwise we want to show the call missed tips modal
            guard
                let infoMessageData: Data = (cellViewModel.rawBody ?? "").data(using: .utf8),
                let messageInfo: CallMessage.MessageInfo = try? JSONDecoder().decode(
                    CallMessage.MessageInfo.self,
                    from: infoMessageData
                ),
                messageInfo.state == .permissionDeniedMicrophone
            else {
                let callMissedTipsModal: CallMissedTipsModal = CallMissedTipsModal(
                    caller: cellViewModel.authorName,
                    presentingViewController: self,
                    using: viewModel.dependencies
                )
                present(callMissedTipsModal, animated: true, completion: nil)
                return
            }
            return
        }
        
        // For disappearing messages config update, show the following settings modal
        guard cellViewModel.variant != .infoDisappearingMessagesUpdate else {
            let messageDisappearingConfig = cellViewModel.messageDisappearingConfiguration()
            let expirationTimerString: String = floor(messageDisappearingConfig.durationSeconds).formatted(format: .long)
            let expirationTypeString: String = (messageDisappearingConfig.type?.localizedName ?? "")
            let modalBodyString: String = {
                if messageDisappearingConfig.isEnabled {
                    return "disappearingMessagesFollowSettingOn"
                        .put(key: "time", value: expirationTimerString)
                        .put(key: "disappearing_messages_type", value: expirationTypeString)
                        .localized()
                } else {
                    return "disappearingMessagesFollowSettingOff"
                        .localized()
                }
            }()
            let modalConfirmTitle: String = messageDisappearingConfig.isEnabled ? "set".localized() : "confirm".localized()
            let confirmationModal: ConfirmationModal = ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: "disappearingMessagesFollowSetting".localized(),
                    body: .attributedText(modalBodyString.formatted(baseFont: .systemFont(ofSize: Values.smallFontSize))),
                    confirmTitle: modalConfirmTitle,
                    confirmStyle: .danger,
                    cancelStyle: .textPrimary,
                    dismissOnConfirm: false // Custom dismissal logic
                ) { [weak self, dependencies = viewModel.dependencies] _ in
                    dependencies[singleton: .storage].writeAsync { db in
                        let userSessionId: SessionId = dependencies[cache: .general].sessionId
                        let currentTimestampMs: Int64 = dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
                        
                        let interactionId = try messageDisappearingConfig
                            .upserted(db)
                            .insertControlMessage(
                                db,
                                threadVariant: cellViewModel.threadVariant,
                                authorId: userSessionId.hexString,
                                timestampMs: currentTimestampMs,
                                serverHash: nil,
                                serverExpirationTimestamp: nil,
                                using: dependencies
                            )?
                            .interactionId
                        
                        let expirationTimerUpdateMessage: ExpirationTimerUpdate = ExpirationTimerUpdate()
                            .with(sentTimestampMs: UInt64(currentTimestampMs))
                            .with(messageDisappearingConfig)

                        try MessageSender.send(
                            db,
                            message: expirationTimerUpdateMessage,
                            interactionId: interactionId,
                            threadId: cellViewModel.threadId,
                            threadVariant: cellViewModel.threadVariant,
                            using: dependencies
                        )
                        
                        try LibSession
                            .update(
                                db,
                                sessionId: cellViewModel.threadId,
                                disappearingMessagesConfig: messageDisappearingConfig,
                                using: dependencies
                            )
                    }
                    self?.dismiss(animated: true, completion: nil)
                }
            )
            
            present(confirmationModal, animated: true, completion: nil)
            return
        }
        
        // If it's an incoming media message and the thread isn't trusted then show the placeholder view
        if cellViewModel.cellType != .textOnlyMessage && cellViewModel.variant == .standardIncoming && !cellViewModel.threadIsTrusted {
            let message: ThemedAttributedString = "attachmentsAutoDownloadModalDescription"
                .put(key: "conversation_name", value: cellViewModel.authorName)
                .localizedFormatted(baseFont: .systemFont(ofSize: Values.smallFontSize))
            let confirmationModal: ConfirmationModal = ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: "attachmentsAutoDownloadModalTitle".localized(),
                    body: .attributedText(message),
                    confirmTitle: "download".localized(),
                    dismissOnConfirm: false // Custom dismissal logic
                ) { [weak self] _ in
                    self?.viewModel.trustContact()
                    self?.dismiss(animated: true, completion: nil)
                }
            )
            
            present(confirmationModal, animated: true, completion: nil)
            return
        }
        
        /// Takes the `cell` and a `targetView` and returns `true` if the user tapped a link in the cell body text instead
        /// of the `targetView`
        func handleLinkTapIfNeeded(cell: UITableViewCell, targetView: UIView?) -> Bool {
            let locationInTargetView: CGPoint = cell.convert(cellLocation, to: targetView)
            
            guard
                let visibleCell: VisibleMessageCell = cell as? VisibleMessageCell,
                targetView?.bounds.contains(locationInTargetView) != true,
                visibleCell.bodyTappableLabel?.containsLinks == true
            else { return false }
            
            let tappableLabelPoint: CGPoint = cell.convert(cellLocation, to: visibleCell.bodyTappableLabel)
            visibleCell.bodyTappableLabel?.handleTouch(at: tappableLabelPoint)
            return true
        }
        
        switch cellViewModel.cellType {
            case .voiceMessage: viewModel.playOrPauseAudio(for: cellViewModel)
            
            case .mediaMessage:
                guard
                    let albumView: MediaAlbumView = (cell as? VisibleMessageCell)?.albumView,
                    !handleLinkTapIfNeeded(cell: cell, targetView: albumView)
                else { return }
                
                // Figure out which of the media views was tapped
                let locationInAlbumView: CGPoint = cell.convert(cellLocation, to: albumView)
                guard let mediaView = albumView.mediaView(forLocation: locationInAlbumView) else { return }
                
                switch mediaView.attachment.state {
                    case .pendingDownload, .downloading, .uploading, .invalid: break
                    
                    // Failed uploads should be handled via the "resend" process instead
                    case .failedUpload: break
                        
                    case .failedDownload:
                        let threadId: String = self.viewModel.threadData.threadId
                        
                        // Retry downloading the failed attachment
                        viewModel.dependencies[singleton: .storage].writeAsync { [dependencies = viewModel.dependencies] db in
                            dependencies[singleton: .jobRunner].add(
                                db,
                                job: Job(
                                    variant: .attachmentDownload,
                                    threadId: threadId,
                                    interactionId: cellViewModel.id,
                                    details: AttachmentDownloadJob.Details(
                                        attachmentId: mediaView.attachment.id
                                    )
                                ),
                                canStartJob: true
                            )
                        }
                        break
                        
                    default:
                        // Ignore invalid media
                        guard mediaView.attachment.isValid else { return }
                        
                        guard albumView.numItems > 1 || !mediaView.attachment.isVideo else {
                            guard
                                let path: String = try? viewModel.dependencies[singleton: .attachmentManager]
                                    .createTemporaryFileForOpening(
                                        downloadUrl: mediaView.attachment.downloadUrl,
                                        mimeType: mediaView.attachment.contentType,
                                        sourceFilename: mediaView.attachment.sourceFilename
                                    ),
                                viewModel.dependencies[singleton: .fileManager].fileExists(atPath: path)
                            else { return Log.warn(.conversation, "Missing video file") }
                            
                            /// When playing media we need to change the AVAudioSession to 'playback' mode so the device "silent mode"
                            /// doesn't prevent video audio from playing
                            try? AVAudioSession.sharedInstance().setCategory(.playback)
                            let viewController: DismissCallbackAVPlayerViewController = DismissCallbackAVPlayerViewController { [dependencies = viewModel.dependencies] in
                                /// Sanity check to make sure we don't unintentionally remove a proper attachment file
                                guard path.hasPrefix(dependencies[singleton: .fileManager].temporaryDirectory) else {
                                    return
                                }
                                
                                try? dependencies[singleton: .fileManager].removeItem(atPath: path)
                            }
                            viewController.player = AVPlayer(url: URL(fileURLWithPath: path))
                            self.present(viewController, animated: true)
                            return
                        }
                        
                        let viewController: UIViewController? = MediaGalleryViewModel.createDetailViewController(
                            for: self.viewModel.threadData.threadId,
                            threadVariant: self.viewModel.threadData.threadVariant,
                            interactionId: cellViewModel.id,
                            selectedAttachmentId: mediaView.attachment.id,
                            options: [ .sliderEnabled, .showAllMediaButton ],
                            using: viewModel.dependencies
                        )
                        
                        if let viewController: UIViewController = viewController {
                            /// Delay becoming the first responder to make the return transition a little nicer (allows
                            /// for the footer on the detail view to slide out rather than instantly vanish)
                            self.delayFirstResponder = true
                            
                            /// Dismiss the input before starting the presentation to make everything look smoother
                            self.resignFirstResponder()
                            
                            /// Delay the actual presentation to give the 'resignFirstResponder' call the chance to complete
                            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
                                /// Lock the contentOffset of the tableView so the transition doesn't look buggy
                                self?.tableView.lockContentOffset = true
                                
                                self?.present(viewController, animated: true) { [weak self] in
                                    // Unlock the contentOffset so everything will be in the right
                                    // place when we return
                                    self?.tableView.lockContentOffset = false
                                }
                            }
                        }
                }
                
            case .audio:
                guard
                    !handleLinkTapIfNeeded(cell: cell, targetView: (cell as? VisibleMessageCell)?.documentView),
                    let attachment: Attachment = cellViewModel.attachments?.first,
                    let path: String = try? viewModel.dependencies[singleton: .attachmentManager]
                        .createTemporaryFileForOpening(
                            downloadUrl: attachment.downloadUrl,
                            mimeType: attachment.contentType,
                            sourceFilename: attachment.sourceFilename
                        ),
                    viewModel.dependencies[singleton: .fileManager].fileExists(atPath: path)
                else { return }
                
                /// When playing media we need to change the AVAudioSession to 'playback' mode so the device "silent mode"
                /// doesn't prevent video audio from playing
                try? AVAudioSession.sharedInstance().setCategory(.playback)
                let viewController: DismissCallbackAVPlayerViewController = DismissCallbackAVPlayerViewController { [dependencies = viewModel.dependencies] in
                    /// Sanity check to make sure we don't unintentionally remove a proper attachment file
                    guard path.hasPrefix(dependencies[singleton: .fileManager].temporaryDirectory) else {
                        return
                    }
                    
                    try? dependencies[singleton: .fileManager].removeItem(atPath: path)
                }
                viewController.player = AVPlayer(url: URL(fileURLWithPath: path))
                self.navigationController?.present(viewController, animated: true)
                
            case .genericAttachment:
                guard
                    !handleLinkTapIfNeeded(cell: cell, targetView: (cell as? VisibleMessageCell)?.documentView),
                    let attachment: Attachment = cellViewModel.attachments?.first,
                    let path: String = try? viewModel.dependencies[singleton: .attachmentManager]
                        .createTemporaryFileForOpening(
                            downloadUrl: attachment.downloadUrl,
                            mimeType: attachment.contentType,
                            sourceFilename: attachment.sourceFilename
                        ),
                    viewModel.dependencies[singleton: .fileManager].fileExists(atPath: path)
                else { return }
                
                let fileUrl: URL = URL(fileURLWithPath: path)
                
                // Open a preview of the document for text, pdf or microsoft files
                if
                    attachment.isText ||
                    attachment.isMicrosoftDoc ||
                    attachment.contentType == UTType.mimeTypePdf
                {
                    // FIXME: If given an invalid text file (eg with binary data) this hangs forever
                    // Note: I tried dispatching after a short delay, detecting that the new UI is invalid and dismissing it
                    // if so but the dismissal didn't work (we may have to wait on Apple to handle this one)
                    let interactionController: UIDocumentInteractionController = UIDocumentInteractionController(url: fileUrl)
                    interactionController.delegate = self
                    interactionController.presentPreview(animated: true)
                    return
                }
                
                // Otherwise share the file
                let shareVC = UIActivityViewController(activityItems: [ fileUrl ], applicationActivities: nil)
                shareVC.completionWithItemsHandler = { [dependencies = viewModel.dependencies] _, success, _, _ in
                    UIActivityViewController.notifyIfNeeded(success, using: dependencies)
                }
                
                if UIDevice.current.isIPad {
                    shareVC.excludedActivityTypes = []
                    shareVC.popoverPresentationController?.permittedArrowDirections = []
                    shareVC.popoverPresentationController?.sourceView = self.view
                    shareVC.popoverPresentationController?.sourceRect = self.view.bounds
                }
                
                navigationController?.present(shareVC, animated: true, completion: nil)
                
            case .textOnlyMessage:
                guard let visibleCell: VisibleMessageCell = cell as? VisibleMessageCell else { return }
                
                let quotePoint: CGPoint = visibleCell.convert(cellLocation, to: visibleCell.quoteView)
                let linkPreviewPoint: CGPoint = visibleCell.convert(cellLocation, to: visibleCell.linkPreviewView?.previewView)
                let tappableLabelPoint: CGPoint = visibleCell.convert(cellLocation, to: visibleCell.bodyTappableLabel)
                let containsLinks: Bool = (
                    // If there is only a single link and it matches the LinkPreview then consider this _just_ a
                    // LinkPreview
                    visibleCell.bodyTappableLabel?.containsLinks == true && (
                        (visibleCell.bodyTappableLabel?.links.count ?? 0) > 1 ||
                        visibleCell.bodyTappableLabel?.links[cellViewModel.linkPreview?.url ?? ""] == nil
                    )
                )
                let quoteViewContainsTouch: Bool = (visibleCell.quoteView?.bounds.contains(quotePoint) == true)
                let linkPreviewViewContainsTouch: Bool = (visibleCell.linkPreviewView?.previewView.bounds.contains(linkPreviewPoint) == true)
                
                switch (containsLinks, quoteViewContainsTouch, linkPreviewViewContainsTouch, cellViewModel.quote, cellViewModel.linkPreview) {
                    // If the message contains both links and a quote, and the user tapped on the quote; OR the
                    // message only contained a quote, then scroll to the quote
                    case (true, true, _, .some(let quote), _), (false, _, _, .some(let quote), _):
                        let maybeOriginalInteractionInfo: Interaction.TimestampInfo? = viewModel.dependencies[singleton: .storage].read { db in
                            try quote.originalInteraction
                                .select(.id, .timestampMs)
                                .asRequest(of: Interaction.TimestampInfo.self)
                                .fetchOne(db)
                        }
                        
                        guard let interactionInfo: Interaction.TimestampInfo = maybeOriginalInteractionInfo else {
                            return
                        }
                        
                        self.scrollToInteractionIfNeeded(
                            with: interactionInfo,
                            focusBehaviour: .highlight,
                            originalIndexPath: self.tableView.indexPath(for: cell)
                        )
                    
                    // If the message contains both links and a LinkPreview, and the user tapped on
                    // the LinkPreview; OR the message only contained a LinkPreview, then open the link
                    case (true, _, true, _, .some(let linkPreview)), (false, _, _, _, .some(let linkPreview)):
                        switch linkPreview.variant {
                            case .standard: openUrl(linkPreview.url)
                            case .openGroupInvitation: joinOpenGroup(name: linkPreview.title, url: linkPreview.url)
                        }
                    
                    // If the message contained links then interact with them directly
                    case (true, _, _, _, _): visibleCell.bodyTappableLabel?.handleTouch(at: tappableLabelPoint)
                        
                    default: break
                }
                
            default: break
        }
    }
    
    func handleItemDoubleTapped(_ cellViewModel: MessageViewModel) {
        switch cellViewModel.cellType {
            // The user can double tap a voice message when it's playing to speed it up
            case .voiceMessage: self.viewModel.speedUpAudio(for: cellViewModel)
            default: break
        }
    }

    func handleItemSwiped(_ cellViewModel: MessageViewModel, state: SwipeState) {
        switch state {
            case .began: tableView.isScrollEnabled = false
            case .ended, .cancelled: tableView.isScrollEnabled = true
        }
    }
    
    func openUrl(_ urlString: String) {
        guard let url: URL = URL(string: urlString) else { return }
        
        let modal: ConfirmationModal = ConfirmationModal(
            targetView: self.view,
            info: ConfirmationModal.Info(
                title: "urlOpen".localized(),
                body: .attributedText(
                    "urlOpenDescription"
                        .put(key: "url", value: url.absoluteString)
                        .localizedFormatted(baseFont: .systemFont(ofSize: Values.smallFontSize))
                ),
                confirmTitle: "open".localized(),
                confirmStyle: .danger,
                cancelTitle: "urlCopy".localized(),
                cancelStyle: .alert_text,
                hasCloseButton: true,
                onConfirm:  { [weak self] modal in
                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                    self?.showInputAccessoryView()
                    
                    modal.dismiss(animated: true)
                },
                onCancel: { [weak self] modal in
                    UIPasteboard.general.string = url.absoluteString
                    
                    modal.dismiss(animated: true) {
                        self?.showInputAccessoryView()
                    }
                }
            )
        )
        
        self.present(modal, animated: true) { [weak self] in
            self?.hideInputAccessoryView()
        }
    }
    
    func handleReplyButtonTapped(for cellViewModel: MessageViewModel) {
        reply(cellViewModel, completion: nil)
    }
    
    func startThread(
        with sessionId: String,
        openGroupServer: String?,
        openGroupPublicKey: String?
    ) {
        guard viewModel.threadData.threadCanWrite == true else { return }
        // FIXME: Add in support for starting a thread with a 'blinded25' id (disabled until we support this decoding)
        guard (try? SessionId.Prefix(from: sessionId)) != .blinded25 else { return }
        guard (try? SessionId.Prefix(from: sessionId)) == .blinded15 else {
            viewModel.dependencies[singleton: .storage].write { [dependencies = viewModel.dependencies] db in
                try SessionThread.upsert(
                    db,
                    id: sessionId,
                    variant: .contact,
                    values: SessionThread.TargetValues(
                        creationDateTimestamp: .useExistingOrSetTo(
                            (dependencies[cache: .snodeAPI].currentOffsetTimestampMs() / 1000)
                        ),
                        shouldBeVisible: .useLibSession,
                        isDraft: .useExistingOrSetTo(true)
                    ),
                    using: dependencies
                )
            }
            
            let conversationVC: ConversationVC = ConversationVC(
                threadId: sessionId,
                threadVariant: .contact,
                using: viewModel.dependencies
            )
                
            self.navigationController?.pushViewController(conversationVC, animated: true)
            return
        }
        
        // If the sessionId is blinded then check if there is an existing un-blinded thread with the contact
        // and use that, otherwise just use the blinded id
        guard let openGroupServer: String = openGroupServer, let openGroupPublicKey: String = openGroupPublicKey else {
            return
        }
        
        let targetThreadId: String? = viewModel.dependencies[singleton: .storage].write { [dependencies = viewModel.dependencies] db in
            let lookup: BlindedIdLookup = try BlindedIdLookup
                .fetchOrCreate(
                    db,
                    blindedId: sessionId,
                    openGroupServer: openGroupServer,
                    openGroupPublicKey: openGroupPublicKey,
                    isCheckingForOutbox: false,
                    using: dependencies
                )
            
            return try SessionThread.upsert(
                db,
                id: (lookup.sessionId ?? lookup.blindedId),
                variant: .contact,
                values: SessionThread.TargetValues(
                    creationDateTimestamp: .useExistingOrSetTo(
                        (dependencies[cache: .snodeAPI].currentOffsetTimestampMs() / 1000)
                    ),
                    shouldBeVisible: .useLibSession,
                    isDraft: .useExistingOrSetTo(true)
                ),
                using: dependencies
            ).id
        }
        
        guard let threadId: String = targetThreadId else { return }
        
        let conversationVC: ConversationVC = ConversationVC(
            threadId: threadId,
            threadVariant: .contact,
            using: viewModel.dependencies
        )
        self.navigationController?.pushViewController(conversationVC, animated: true)
    }
    
    func showReactionList(_ cellViewModel: MessageViewModel, selectedReaction: EmojiWithSkinTones?) {
        guard
            cellViewModel.reactionInfo?.isEmpty == false &&
            (
                self.viewModel.threadData.threadVariant == .legacyGroup ||
                self.viewModel.threadData.threadVariant == .group ||
                self.viewModel.threadData.threadVariant == .community
            ),
            let allMessages: [MessageViewModel] = self.viewModel.interactionData
                .first(where: { $0.model == .messages })?
                .elements
        else { return }
        
        let reactionListSheet: ReactionListSheet = ReactionListSheet(for: cellViewModel.id, using: viewModel.dependencies) { [weak self] in
            self?.currentReactionListSheet = nil
        }
        reactionListSheet.delegate = self
        reactionListSheet.handleInteractionUpdates(
            allMessages,
            selectedReaction: selectedReaction,
            initialLoad: true,
            shouldShowClearAllButton: viewModel.dependencies[singleton: .openGroupManager].isUserModeratorOrAdmin(
                publicKey: self.viewModel.threadData.currentUserSessionId,
                for: self.viewModel.threadData.openGroupRoomToken,
                on: self.viewModel.threadData.openGroupServer,
                currentUserSessionIds: (self.viewModel.threadData.currentUserSessionIds ?? [])
            )
        )
        reactionListSheet.modalPresentationStyle = .overFullScreen
        present(reactionListSheet, animated: true, completion: nil)
        
        // Store so we can updated the content based on the current VC
        self.currentReactionListSheet = reactionListSheet
    }
    
    func needsLayout(for cellViewModel: MessageViewModel, expandingReactions: Bool) {
        guard
            let messageSectionIndex: Int = self.viewModel.interactionData
                .firstIndex(where: { $0.model == .messages }),
            let targetMessageIndex = self.viewModel.interactionData[messageSectionIndex]
                .elements
                .firstIndex(where: { $0.id == cellViewModel.id })
        else { return }
        
        if expandingReactions {
            self.viewModel.expandReactions(for: cellViewModel.id)
        }
        else {
            self.viewModel.collapseReactions(for: cellViewModel.id)
        }
        
        UIView.setAnimationsEnabled(false)
        tableView.reloadRows(
            at: [IndexPath(row: targetMessageIndex, section: messageSectionIndex)],
            with: .none
        )
        
        // Only re-enable animations if the feature flag isn't disabled
        if viewModel.dependencies[feature: .animationsEnabled] {
            UIView.setAnimationsEnabled(true)
        }
    }
    
    func handleReadMoreButtonTapped(_ cell: UITableViewCell, for cellViewModel: MessageViewModel) {
        self.viewModel.expandMessage(for: cellViewModel.id)
        
        UIView.setAnimationsEnabled(false)
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
        tableView.beginUpdates()
        tableView.endUpdates()
        
        // Only re-enable animations if the feature flag isn't disabled
        if viewModel.dependencies[feature: .animationsEnabled] {
            UIView.setAnimationsEnabled(true)
        }
    }
    
    func react(_ cellViewModel: MessageViewModel, with emoji: EmojiWithSkinTones) {
        react(cellViewModel, with: emoji.rawValue, remove: false)
    }
    
    func removeReact(_ cellViewModel: MessageViewModel, for emoji: EmojiWithSkinTones) {
        guard viewModel.threadData.threadVariant != .legacyGroup else { return }
        
        react(cellViewModel, with: emoji.rawValue, remove: true)
    }
    
    func removeAllReactions(_ cellViewModel: MessageViewModel, for emoji: String) {
        // Dismiss current reaction sheet to present alert dialog
        currentReactionListSheet?.dismiss(animated: true)
        currentReactionListSheet = nil
        
        let modal: ConfirmationModal = ConfirmationModal(
            info: ConfirmationModal.Info(
                title: "clearAll".localized(),
                body: .attributedText(
                    "emojiReactsClearAll"
                        .put(key: "emoji", value: emoji)
                        .localizedFormatted(baseFont: ConfirmationModal.explanationFont)
                ),
                confirmTitle: "clear".localized(),
                confirmStyle: .danger,
                cancelStyle: .alert_text,
                onConfirm: { [weak self] modal in
                    // Call clear reaction event
                    self?.clearAllReactions(cellViewModel, for: emoji)
                    modal.dismiss(animated: true)
                }
            )
        )
        
        present(modal, animated: true, completion: nil)
    }
    
    func clearAllReactions(_ cellViewModel: MessageViewModel, for emoji: String) {
        guard
            cellViewModel.threadVariant == .community,
            let roomToken: String = viewModel.threadData.openGroupRoomToken,
            let server: String = viewModel.threadData.openGroupServer,
            let publicKey: String = viewModel.threadData.openGroupPublicKey,
            let capabilities: Set<Capability.Variant> = viewModel.threadData.openGroupCapabilities,
            let openGroupServerMessageId: Int64 = cellViewModel.openGroupServerMessageId
        else { return }
        
        let pendingChange: OpenGroupManager.PendingChange = viewModel.dependencies[singleton: .openGroupManager]
            .addPendingReaction(
                emoji: emoji,
                id: openGroupServerMessageId,
                in: roomToken,
                on: server,
                type: .removeAll
            )
        
        Result {
            try Network.SOGS.preparedReactionDeleteAll(
                emoji: emoji,
                id: openGroupServerMessageId,
                roomToken: roomToken,
                authMethod: Authentication.community(
                    info: LibSession.OpenGroupCapabilityInfo(
                        roomToken: roomToken,
                        server: server,
                        publicKey: publicKey,
                        capabilities: capabilities
                    )
                ),
                using: viewModel.dependencies
            )
        }
        .publisher
        .flatMap { [dependencies = viewModel.dependencies] in $0.send(using: dependencies) }
        .subscribe(on: DispatchQueue.global(qos: .userInitiated), using: viewModel.dependencies)
        .sinkUntilComplete(
            receiveCompletion: { [dependencies = viewModel.dependencies] _ in
                dependencies[singleton: .storage].writeAsync { db in
                    _ = try Reaction
                        .filter(Reaction.Columns.interactionId == cellViewModel.id)
                        .filter(Reaction.Columns.emoji == emoji)
                        .deleteAll(db)
                }
            },
            receiveValue: { [dependencies = viewModel.dependencies] _, response in
                dependencies[singleton: .openGroupManager].updatePendingChange(
                    pendingChange,
                    seqNo: response.seqNo
                )
            }
        )
    }
    
    func react(_ cellViewModel: MessageViewModel, with emoji: String, remove: Bool) {
        guard
            self.viewModel.threadData.threadIsMessageRequest != true && (
                cellViewModel.variant == .standardIncoming ||
                cellViewModel.variant == .standardOutgoing
            )
        else { return }
        
        // Perform local rate limiting (don't allow more than 20 reactions within 60 seconds)
        let threadId: String = self.viewModel.threadData.threadId
        let threadVariant: SessionThread.Variant = self.viewModel.threadData.threadVariant
        let openGroupRoom: String? = self.viewModel.threadData.openGroupRoomToken
        let sentTimestampMs: Int64 = viewModel.dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
        let recentReactionTimestamps: [Int64] = viewModel.dependencies[cache: .general].recentReactionTimestamps
        
        guard
            recentReactionTimestamps.count < 20 ||
            (sentTimestampMs - (recentReactionTimestamps.first ?? sentTimestampMs)) > (60 * 1000)
        else {
            let toastController: ToastController = ToastController(
                text: "emojiReactsCoolDown".localized(),
                background: .backgroundSecondary
            )
            toastController.presentToastView(
                fromBottomOfView: self.view,
                inset: (snInputView.bounds.height + Values.largeSpacing),
                duration: .milliseconds(2500)
            )
            return
        }
        
        viewModel.dependencies.mutate(cache: .general) {
            $0.recentReactionTimestamps = Array($0.recentReactionTimestamps
                .suffix(19))
                .appending(sentTimestampMs)
        }
        
        typealias OpenGroupInfo = (
            pendingReaction: Reaction?,
            pendingChange: OpenGroupManager.PendingChange,
            preparedRequest: Network.PreparedRequest<Int64?>
        )
        
        /// Perform the sending logic, we generate the pending reaction first in a deferred future closure to prevent the OpenGroup
        /// cache from blocking either the main thread or the database write thread
        Deferred { [dependencies = viewModel.dependencies] in
            Future<OpenGroupManager.PendingChange?, Error> { resolver in
                guard
                    threadVariant == .community,
                    let serverMessageId: Int64 = cellViewModel.openGroupServerMessageId,
                    let openGroupServer: String = cellViewModel.threadOpenGroupServer,
                    let openGroupPublicKey: String = cellViewModel.threadOpenGroupPublicKey
                else { return resolver(Result.success(nil)) }
                  
                // Create the pending change if we have open group info
                return resolver(Result.success(
                    dependencies[singleton: .openGroupManager].addPendingReaction(
                        emoji: emoji,
                        id: serverMessageId,
                        in: openGroupServer,
                        on: openGroupPublicKey,
                        type: (remove ? .remove : .add)
                    )
                ))
            }
        }
        .subscribe(on: DispatchQueue.global(qos: .userInitiated), using: viewModel.dependencies)
        .flatMapStorageWritePublisher(using: viewModel.dependencies) { [weak self, dependencies = viewModel.dependencies] db, pendingChange -> (OpenGroupManager.PendingChange?, Reaction?, Message.Destination, AuthenticationMethod) in
            // Update the thread to be visible (if it isn't already)
            if self?.viewModel.threadData.threadShouldBeVisible == false {
                try SessionThread.updateVisibility(
                    db,
                    threadId: cellViewModel.threadId,
                    isVisible: true,
                    using: dependencies
                )
            }
            
            let pendingReaction: Reaction? = {
                guard !remove else {
                    return try? Reaction
                        .filter(Reaction.Columns.interactionId == cellViewModel.id)
                    // TODO: [Database Relocation] Stop `currentUserSessionIds` from being nullable
                        .filter((cellViewModel.currentUserSessionIds ?? []).contains(Reaction.Columns.authorId))
                        .filter(Reaction.Columns.emoji == emoji)
                        .fetchOne(db)
                }
                
                let sortId: Int64 = Reaction.getSortId(
                    db,
                    interactionId: cellViewModel.id,
                    emoji: emoji
                )
                
                return Reaction(
                    interactionId: cellViewModel.id,
                    serverHash: nil,
                    timestampMs: sentTimestampMs,
                    authorId: cellViewModel.currentUserSessionId,
                    emoji: emoji,
                    count: 1,
                    sortId: sortId
                )
            }()
            
            // Update the database
            if remove {
                try Reaction
                    .filter(Reaction.Columns.interactionId == cellViewModel.id)
                // TODO: [Database Relocation] Stop `currentUserSessionIds` from being nullable
                    .filter((cellViewModel.currentUserSessionIds ?? []).contains(Reaction.Columns.authorId))
                    .filter(Reaction.Columns.emoji == emoji)
                    .deleteAll(db)
            }
            else {
                try pendingReaction?.insert(db)
                
                // Add it to the recent list
                Emoji.addRecent(db, emoji: emoji)
            }
            
            switch threadVariant {
                case .community:
                    guard
                        let openGroupServer: String = cellViewModel.threadOpenGroupServer,
                        dependencies[singleton: .openGroupManager].doesOpenGroupSupport(db, capability: .reactions, on: openGroupServer)
                    else { throw MessageSenderError.invalidMessage }
                    
                default: break
            }
            
            return (
                pendingChange,
                pendingReaction,
                try Message.Destination.from(db, threadId: threadId, threadVariant: threadVariant),
                try Authentication.with(db, threadId: threadId, threadVariant: threadVariant, using: dependencies)
            )
        }
        .tryFlatMap { [dependencies = viewModel.dependencies] pendingChange, pendingReaction, destination, authMethod in
            switch threadVariant {
                case .community:
                    guard
                        let serverMessageId: Int64 = cellViewModel.openGroupServerMessageId,
                        let openGroupServer: String = cellViewModel.threadOpenGroupServer,
                        let openGroupRoom: String = openGroupRoom,
                        let pendingChange: OpenGroupManager.PendingChange = pendingChange
                    else { throw MessageSenderError.invalidMessage }
                    
                    let preparedRequest: Network.PreparedRequest<Int64?> = try {
                        guard !remove else {
                            return try Network.SOGS
                                .preparedReactionDelete(
                                    emoji: emoji,
                                    id: serverMessageId,
                                    roomToken: openGroupRoom,
                                    authMethod: authMethod,
                                    using: dependencies
                                )
                                .map { _, response in response.seqNo }
                        }
                        
                        return try Network.SOGS
                            .preparedReactionAdd(
                                emoji: emoji,
                                id: serverMessageId,
                                roomToken: openGroupRoom,
                                authMethod: authMethod,
                                using: dependencies
                            )
                            .map { _, response in response.seqNo }
                    }()
                    
                    return preparedRequest
                        .handleEvents(
                            receiveOutput: { _, seqNo in
                                dependencies[singleton: .openGroupManager].updatePendingChange(
                                    pendingChange,
                                    seqNo: seqNo
                                )
                            },
                            receiveCompletion: { [weak self] result in
                                switch result {
                                    case .finished: break
                                    case .failure:
                                        dependencies[singleton: .openGroupManager].removePendingChange(pendingChange)
                                        
                                        self?.handleReactionSentFailure(pendingReaction, remove: remove)
                                }
                            }
                        )
                        .map { _, _ in () }
                        .send(using: dependencies)
                    
                default:
                    return try MessageSender.preparedSend(
                        message: VisibleMessage(
                            sentTimestampMs: UInt64(sentTimestampMs),
                            text: nil,
                            reaction: VisibleMessage.VMReaction(
                                timestamp: UInt64(cellViewModel.timestampMs),
                                publicKey: {
                                    guard cellViewModel.variant == .standardIncoming else {
                                        return cellViewModel.currentUserSessionId
                                    }
                                    
                                    return cellViewModel.authorId
                                }(),
                                emoji: emoji,
                                kind: (remove ? .remove : .react)
                            )
                        ),
                        to: destination,
                        namespace: destination.defaultNamespace,
                        interactionId: cellViewModel.id,
                        attachments: nil,
                        authMethod: authMethod,
                        onEvent: MessageSender.standardEventHandling(using: dependencies),
                        using: dependencies
                    )
                    .map { _, _ in () }
                    .send(using: dependencies)
            }
        }
        .sinkUntilComplete()
    }
    
    func handleReactionSentFailure(_ pendingReaction: Reaction?, remove: Bool) {
        guard let pendingReaction = pendingReaction else { return }
        viewModel.dependencies[singleton: .storage].writeAsync { db in
            // Reverse the database
            if remove {
                try pendingReaction.insert(db)
            }
            else {
                try Reaction
                    .filter(Reaction.Columns.interactionId == pendingReaction.interactionId)
                    .filter(Reaction.Columns.authorId == pendingReaction.authorId)
                    .filter(Reaction.Columns.emoji == pendingReaction.emoji)
                    .deleteAll(db)
            }
        }
    }
    
    func showFullEmojiKeyboard(_ cellViewModel: MessageViewModel) {
        hideInputAccessoryView()
        
        let emojiPicker = EmojiPickerSheet(
            completionHandler: { [weak self] emoji in
                guard let emoji: EmojiWithSkinTones = emoji else { return }
                
                self?.react(cellViewModel, with: emoji)
            },
            dismissHandler: { [weak self] in
                self?.showInputAccessoryView()
            },
            using: self.viewModel.dependencies
        )
        
        present(emojiPicker, animated: true, completion: nil)
    }
    
    func contextMenuDismissed() {
        recoverInputView()
    }
    
    // MARK: --action handling
    
    func joinOpenGroup(name: String?, url: String) {
        // Open groups can be unsafe, so always ask the user whether they want to join one
        let modal: ConfirmationModal = ConfirmationModal(
            info: ConfirmationModal.Info(
                title: "communityJoin".localized(),
                body: .attributedText(
                    "communityJoinDescription"
                        .put(key: "community_name", value: (name ?? "communityUnknown".localized()))
                        .localizedFormatted(baseFont: ConfirmationModal.explanationFont)
                ),
                confirmTitle: "join".localized(),
                onConfirm: { [dependencies = viewModel.dependencies] modal in
                    guard let presentingViewController: UIViewController = modal.presentingViewController else {
                        return
                    }
                    
                    guard let (room, server, publicKey) = LibSession.parseCommunity(url: url) else {
                        let errorModal: ConfirmationModal = ConfirmationModal(
                            info: ConfirmationModal.Info(
                                title: "communityJoinError".localized(),
                                cancelTitle: "okay".localized(),
                                cancelStyle: .alert_text
                            )
                        )
                        
                        return presentingViewController.present(errorModal, animated: true, completion: nil)
                    }
                    
                    dependencies[singleton: .storage]
                        .writePublisher { db in
                            dependencies[singleton: .openGroupManager].add(
                                db,
                                roomToken: room,
                                server: server,
                                publicKey: publicKey,
                                forceVisible: false
                            )
                        }
                        .flatMap { successfullyAddedGroup in
                            dependencies[singleton: .openGroupManager].performInitialRequestsAfterAdd(
                                queue: DispatchQueue.global(qos: .userInitiated),
                                successfullyAddedGroup: successfullyAddedGroup,
                                roomToken: room,
                                server: server,
                                publicKey: publicKey
                            )
                        }
                        .subscribe(on: DispatchQueue.global(qos: .userInitiated))
                        .receive(on: DispatchQueue.main)
                        .sinkUntilComplete(
                            receiveCompletion: { result in
                                switch result {
                                    case .finished: break
                                    case .failure(let error):
                                        // If there was a failure then the group will be in invalid state until
                                        // the next launch so remove it (the user will be left on the previous
                                        // screen so can re-trigger the join)
                                        dependencies[singleton: .storage].writeAsync { db in
                                            try dependencies[singleton: .openGroupManager].delete(
                                                db,
                                                openGroupId: OpenGroup.idFor(roomToken: room, server: server),
                                                skipLibSessionUpdate: false
                                            )
                                        }
                                        
                                        // Show the user an error indicating they failed to properly join the group
                                        let errorModal: ConfirmationModal = ConfirmationModal(
                                            info: ConfirmationModal.Info(
                                                title: "communityJoinError".localized(),
                                                body: .text("\(error)"),
                                                cancelTitle: "okay".localized(),
                                                cancelStyle: .alert_text
                                            )
                                        )
                                        
                                        presentingViewController.present(errorModal, animated: true, completion: nil)
                                }
                            }
                        )
                }
            )
        )
        
        present(modal, animated: true, completion: nil)
    }
    
    // MARK: - ContextMenuActionDelegate
    
    func info(_ cellViewModel: MessageViewModel) {
        let actions: [ContextMenuVC.Action] = ContextMenuVC.actions(
            for: cellViewModel,
            in: self.viewModel.threadData,
            forMessageInfoScreen: true,
            delegate: self,
            using: viewModel.dependencies
        ) ?? []
        
        // FIXME: This is an interim solution until the `ConversationViewModel` queries are refactored to use the new observation system
        var finalCellViewModel: MessageViewModel = cellViewModel
        
        if
            viewModel.threadData.currentUserSessionIds?.contains(cellViewModel.authorId) == true &&
            cellViewModel.authorId != viewModel.threadData.currentUserSessionId
        {
            finalCellViewModel = finalCellViewModel.with(
                profile: viewModel.dependencies.mutate(cache: .libSession) { $0.profile }
            )
        }
        
        let messageInfoViewController = MessageInfoViewController(
            actions: actions,
            messageViewModel: finalCellViewModel,
            using: viewModel.dependencies
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.navigationController?.pushViewController(messageInfoViewController, animated: true)
        }
    }

    func retry(_ cellViewModel: MessageViewModel, completion: (() -> Void)?) {
        guard cellViewModel.id != MessageViewModel.optimisticUpdateId else {
            guard
                let optimisticMessageId: UUID = cellViewModel.optimisticMessageId,
                let optimisticMessageData: ConversationViewModel.OptimisticMessageData = self.viewModel.optimisticMessageData(for: optimisticMessageId)
            else {
                // Show an error for the retry
                let modal: ConfirmationModal = ConfirmationModal(
                    info: ConfirmationModal.Info(
                        title: "theError".localized(),
                        body: .text("shareExtensionDatabaseError".localized()),
                        cancelTitle: "okay".localized(),
                        cancelStyle: .alert_text,
                        afterClosed: {
                            completion?()
                        }
                    )
                )
                
                self.present(modal, animated: true, completion: nil)
                return
            }
            
            // Try to send the optimistic message again
            sendMessage(optimisticData: optimisticMessageData)
            completion?()
            return
        }
        
        viewModel.dependencies[singleton: .storage].writeAsync { [weak self, dependencies = viewModel.dependencies] db in
            guard
                let threadId: String = self?.viewModel.threadData.threadId,
                let threadVariant: SessionThread.Variant = self?.viewModel.threadData.threadVariant,
                let interaction: Interaction = try? Interaction.fetchOne(db, id: cellViewModel.id)
            else { return }
            
            // Remove message sending jobs for the same interaction in database
            // Prevent the same message being sent twice
            try Job.filter(Job.Columns.interactionId == interaction.id).deleteAll(db)
            
            try MessageSender.send(
                db,
                interaction: interaction,
                threadId: threadId,
                threadVariant: threadVariant,
                isSyncMessage: (cellViewModel.state == .failedToSync),
                using: dependencies
            )
        }
        
        completion?()
    }

    func reply(_ cellViewModel: MessageViewModel, completion: (() -> Void)?) {
        let maybeQuoteDraft: QuotedReplyModel? = QuotedReplyModel.quotedReplyForSending(
            threadId: self.viewModel.threadData.threadId,
            authorId: cellViewModel.authorId,
            variant: cellViewModel.variant,
            body: cellViewModel.body,
            timestampMs: cellViewModel.timestampMs,
            attachments: cellViewModel.attachments,
            linkPreviewAttachment: cellViewModel.linkPreviewAttachment,
            currentUserSessionIds: (cellViewModel.currentUserSessionIds ?? [])
        )
        
        guard let quoteDraft: QuotedReplyModel = maybeQuoteDraft else { return }
        
        snInputView.quoteDraftInfo = (
            model: quoteDraft,
            isOutgoing: (cellViewModel.variant == .standardOutgoing)
        )
        
        // If the `MessageInfoViewController` is visible then we want to show the keyboard after
        // the pop transition completes (and don't want to delay triggering the completion closure)
        let messageInfoScreenVisible: Bool = (self.navigationController?.viewControllers.last is MessageInfoViewController)

        guard !messageInfoScreenVisible else {
            if self.isShowingSearchUI == true { self.willManuallyCancelSearchUI() }
            self.hasPendingInputKeyboardPresentationEvent = true
            completion?()
            return
        }
        
        // Add delay before doing any ui updates
        // Delay added to give time for long press actions to dismiss
        let delay = completion == nil ? 0 : ContextMenuVC.dismissDuration
        
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            if self?.isShowingSearchUI == true { self?.willManuallyCancelSearchUI() }
            _ = self?.snInputView.becomeFirstResponder()
            completion?()
        }
    }

    func copy(_ cellViewModel: MessageViewModel, completion: (() -> Void)?) {
        switch cellViewModel.cellType {
            case .typingIndicator, .dateHeader, .unreadMarker: break
            
            case .textOnlyMessage:
                if cellViewModel.body == nil, let linkPreview: LinkPreview = cellViewModel.linkPreview {
                    UIPasteboard.general.string = linkPreview.url
                    return
                }
                
                UIPasteboard.general.string = cellViewModel.body
            
            case .audio, .voiceMessage, .genericAttachment, .mediaMessage:
                guard
                    cellViewModel.attachments?.count == 1,
                    let attachment: Attachment = cellViewModel.attachments?.first,
                    attachment.isValid,
                    (
                        attachment.state == .downloaded ||
                        attachment.state == .uploaded
                    ),
                    let type: UTType = UTType(sessionMimeType: attachment.contentType),
                    let path: String = try? viewModel.dependencies[singleton: .attachmentManager]
                        .path(for: attachment.downloadUrl),
                    let data: Data = try? Data(contentsOf: URL(fileURLWithPath: path))
                else { return }
            
                UIPasteboard.general.setData(data, forPasteboardType: type.identifier)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(ContextMenuVC.dismissDurationPartOne * 1000))) { [weak self] in
            self?.viewModel.showToast(
                text: "copied".localized(),
                backgroundColor: .toast_background,
                inset: Values.largeSpacing + (self?.inputAccessoryView?.frame.height ?? 0)
            )
        }
        
        completion?()
    }

    func copySessionID(_ cellViewModel: MessageViewModel, completion: (() -> Void)?) {
        guard cellViewModel.variant == .standardIncoming else { return }
        
        UIPasteboard.general.string = cellViewModel.authorId
        
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(ContextMenuVC.dismissDurationPartOne * 1000))) { [weak self] in
            self?.viewModel.showToast(
                text: "copied".localized(),
                backgroundColor: .toast_background,
                inset: Values.largeSpacing + (self?.inputAccessoryView?.frame.height ?? 0)
            )
        }
        
        completion?()
    }

    func delete(_ cellViewModel: MessageViewModel, completion: (() -> Void)?) {
        /// Retrieve the deletion actions for the selected message(s) of there are any
        let messagesToDelete: [MessageViewModel] = [cellViewModel]
        
        guard let deletionBehaviours: MessageViewModel.DeletionBehaviours = self.viewModel.deletionActions(for: messagesToDelete) else {
            return
        }
        
        let modal: ConfirmationModal = ConfirmationModal(
            info: ConfirmationModal.Info(
                title: deletionBehaviours.title,
                body: .radio(
                    explanation: ThemedAttributedString(string: deletionBehaviours.body),
                    warning: deletionBehaviours.warning.map { ThemedAttributedString(string: $0) },
                    options: deletionBehaviours.actions.map { action in
                        ConfirmationModal.Info.Body.RadioOptionInfo(
                            title: action.title,
                            enabled: action.state != .disabled,
                            selected: action.state == .enabledAndDefaultSelected,
                            accessibility: action.accessibility
                        )
                    }
                ),
                confirmTitle: "delete".localized(),
                confirmStyle: .danger,
                cancelTitle: "cancel".localized(),
                cancelStyle: .alert_text,
                dismissOnConfirm: false,
                onConfirm: { [weak self, dependencies = viewModel.dependencies] modal in
                    /// Determine the selected action index
                    let selectedIndex: Int = {
                        switch modal.info.body {
                            case .radio(_, _, let options):
                                return options
                                    .enumerated()
                                    .first(where: { _, value in value.selected })
                                    .map { index, _ in index }
                                    .defaulting(to: 0)
                            
                            default: return 0
                        }
                    }()
                    
                    /// Stop the messages audio if needed
                    messagesToDelete.forEach { cellViewModel in
                        self?.viewModel.stopAudioIfNeeded(for: cellViewModel)
                    }
                    
                    /// Trigger the deletion behaviours
                    deletionBehaviours
                        .publisherForAction(at: selectedIndex, using: dependencies)
                        .showingBlockingLoading(
                            in: deletionBehaviours.requiresNetworkRequestForAction(at: selectedIndex) ?
                                self?.viewModel.navigatableState :
                                nil
                        )
                        .sinkUntilComplete(
                            receiveCompletion: { result in
                                DispatchQueue.main.async {
                                    switch result {
                                        case .finished:
                                            modal.dismiss(animated: true) {
                                                /// Dispatch after a delay because becoming the first responder can cause
                                                /// an odd appearance animation
                                                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150)) {
                                                    self?.viewModel.showToast(
                                                        text: "deleteMessageDeleted"
                                                            .putNumber(messagesToDelete.count)
                                                            .localized(),
                                                        backgroundColor: .backgroundSecondary,
                                                        inset: (self?.inputAccessoryView?.frame.height ?? Values.mediumSpacing) + Values.smallSpacing
                                                    )
                                                }
                                            }
                                            
                                        case .failure:
                                            self?.viewModel.showToast(
                                                text: "deleteMessageFailed"
                                                    .putNumber(messagesToDelete.count)
                                                    .localized(),
                                                backgroundColor: .backgroundSecondary,
                                                inset: (self?.inputAccessoryView?.frame.height ?? Values.mediumSpacing) + Values.smallSpacing
                                            )
                                    }
                                    completion?()
                                }
                            }
                        )
                },
                afterClosed: { [weak self] in
                    self?.becomeFirstResponder()
                }
            )
        )
        
        /// Show the modal after a small delay so it doesn't look as weird with the context menu dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(ContextMenuVC.dismissDurationPartOne * 1000))) { [weak self] in
            self?.present(modal, animated: true)
            self?.resignFirstResponder()
        }
    }

    func save(_ cellViewModel: MessageViewModel, completion: (() -> Void)?) {
        let validAttachments: [(Attachment, String)] = (cellViewModel.attachments ?? [])
            .filter { attachment in
                attachment.isValid && (
                    cellViewModel.cellType != .mediaMessage ||
                    attachment.isVisualMedia
                ) && (
                    attachment.state == .downloaded ||
                    attachment.state == .uploaded
                )
            }
            .compactMap { attachment in
                guard
                    let path: String = try? viewModel.dependencies[singleton: .attachmentManager]
                        .createTemporaryFileForOpening(
                            downloadUrl: attachment.downloadUrl,
                            mimeType: attachment.contentType,
                            sourceFilename: attachment.sourceFilename
                        ),
                    viewModel.dependencies[singleton: .fileManager].fileExists(atPath: path)
                else { return nil }
                
                return (attachment, path)
            }
        
        guard !validAttachments.isEmpty else { return }
        
        switch cellViewModel.cellType {
            case .audio, .genericAttachment:
                let documentPicker = UIDocumentPickerViewController(
                    forExporting: validAttachments.map { _, path in URL(fileURLWithPath: path) },
                    asCopy: true
                )
                
                self.documentHandler = DocumentPickerHandler(
                    didPickDocumentsAt: { [weak self, dependencies = viewModel.dependencies] _, _ in
                        validAttachments.forEach { attachment, path in
                            /// Sanity check to make sure we don't unintentionally remove a proper attachment file
                            guard path.hasPrefix(dependencies[singleton: .fileManager].temporaryDirectory) else {
                                return
                            }
                            
                            try? dependencies[singleton: .fileManager].removeItem(atPath: path)
                        }
                        
                        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(ContextMenuVC.dismissDurationPartOne * 1000))) { [weak self] in
                            self?.viewModel.showToast(
                                text: "saved".localized(),
                                backgroundColor: .toast_background,
                                inset: Values.largeSpacing + (self?.inputAccessoryView?.frame.height ?? 0)
                            )
                            
                            // Send a 'media saved' notification if needed
                            guard self?.viewModel.threadData.threadVariant == .contact, cellViewModel.variant == .standardIncoming else {
                                return
                            }
                            
                            self?.sendDataExtraction(kind: .mediaSaved(timestamp: UInt64(cellViewModel.timestampMs)))
                        }
                        
                        self?.showInputAccessoryView()
                        self?.becomeFirstResponder()
                        self?.documentHandler = nil
                    },
                    wasCancelled: { [weak self] _ in
                        self?.showInputAccessoryView()
                        self?.becomeFirstResponder()
                        self?.documentHandler = nil
                    }
                )
                documentPicker.delegate = documentHandler
                present(documentPicker, animated: true)
                
            case .mediaMessage:
                Permissions.requestLibraryPermissionIfNeeded(
                    isSavingMedia: true,
                    presentingViewController: self,
                    using: viewModel.dependencies
                ) { [weak self, dependencies = viewModel.dependencies] in
                    PHPhotoLibrary.shared().performChanges(
                        {
                            validAttachments.forEach { attachment, path in
                                if attachment.isImage || attachment.isAnimated {
                                    PHAssetChangeRequest.creationRequestForAssetFromImage(
                                        atFileURL: URL(fileURLWithPath: path)
                                    )
                                }
                                else if attachment.isVideo {
                                    PHAssetChangeRequest.creationRequestForAssetFromVideo(
                                        atFileURL: URL(fileURLWithPath: path)
                                    )
                                }
                            }
                        },
                        completionHandler: { [weak self, dependencies] _, _ in
                            validAttachments.forEach { attachment, path in
                                /// Sanity check to make sure we don't unintentionally remove a proper attachment file
                                guard path.hasPrefix(dependencies[singleton: .fileManager].temporaryDirectory) else {
                                    return
                                }
                                
                                try? dependencies[singleton: .fileManager].removeItem(atPath: path)
                            }
                            
                            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(ContextMenuVC.dismissDurationPartOne * 1000))) { [weak self] in
                                self?.viewModel.showToast(
                                    text: "saved".localized(),
                                    backgroundColor: .toast_background,
                                    inset: Values.largeSpacing + (self?.inputAccessoryView?.frame.height ?? 0)
                                )
                            }
                            
                            // Send a 'media saved' notification if needed
                            guard self?.viewModel.threadData.threadVariant == .contact, cellViewModel.variant == .standardIncoming else {
                                return
                            }
                            
                            self?.sendDataExtraction(kind: .mediaSaved(timestamp: UInt64(cellViewModel.timestampMs)))
                        }
                    )
                }
                
                completion?()
                
            default: break
        }
    }

    func ban(_ cellViewModel: MessageViewModel, completion: (() -> Void)?) {
        guard cellViewModel.threadVariant == .community else { return }
        
        let modal: ConfirmationModal = ConfirmationModal(
            targetView: self.view,
            info: ConfirmationModal.Info(
                title: "banUser".localized(),
                body: .text("communityBanDescription".localized()),
                confirmTitle: "theContinue".localized(),
                confirmStyle: .danger,
                cancelStyle: .alert_text,
                onConfirm: { [weak self, threadData = viewModel.threadData, dependencies = viewModel.dependencies] _ in
                    Result {
                        guard
                            cellViewModel.threadVariant == .community,
                            let roomToken: String = threadData.openGroupRoomToken,
                            let server: String = threadData.openGroupServer,
                            let publicKey: String = threadData.openGroupPublicKey,
                            let capabilities: Set<Capability.Variant> = threadData.openGroupCapabilities,
                            cellViewModel.openGroupServerMessageId != nil
                        else { throw CryptoError.invalidAuthentication }
                        
                        return (
                            roomToken,
                            Authentication.community(
                                info: LibSession.OpenGroupCapabilityInfo(
                                    roomToken: roomToken,
                                    server: server,
                                    publicKey: publicKey,
                                    capabilities: capabilities
                                )
                            )
                        )
                    }
                    .publisher
                    .tryFlatMap { (roomToken: String, authMethod: AuthenticationMethod) in
                        try Network.SOGS.preparedUserBan(
                            sessionId: cellViewModel.authorId,
                            from: [roomToken],
                            authMethod: authMethod,
                            using: dependencies
                        ).send(using: dependencies)
                    }
                    .subscribe(on: DispatchQueue.global(qos: .userInitiated), using: dependencies)
                    .receive(on: DispatchQueue.main, using: dependencies)
                    .sinkUntilComplete(
                        receiveCompletion: { result in
                            DispatchQueue.main.async { [weak self] in
                                switch result {
                                    case .finished:
                                        self?.viewModel.showToast(
                                            text: "banUserBanned".localized(),
                                            backgroundColor: .backgroundSecondary,
                                            inset: (self?.inputAccessoryView?.frame.height ?? Values.mediumSpacing) + Values.smallSpacing
                                        )
                                    case .failure:
                                        self?.viewModel.showToast(
                                            text: "banErrorFailed".localized(),
                                            backgroundColor: .backgroundSecondary,
                                            inset: (self?.inputAccessoryView?.frame.height ?? Values.mediumSpacing) + Values.smallSpacing
                                        )
                                }
                                completion?()
                            }
                        }
                    )
                    
                    self?.becomeFirstResponder()
                },
                afterClosed: { [weak self] in
                    completion?()
                    self?.becomeFirstResponder()
                }
            )
        )
        self.present(modal, animated: true)
    }

    func banAndDeleteAllMessages(_ cellViewModel: MessageViewModel, completion: (() -> Void)?) {
        guard cellViewModel.threadVariant == .community else { return }
        
        let modal: ConfirmationModal = ConfirmationModal(
            targetView: self.view,
            info: ConfirmationModal.Info(
                title: "banDeleteAll".localized(),
                body: .text("communityBanDeleteDescription".localized()),
                confirmTitle: "theContinue".localized(),
                confirmStyle: .danger,
                cancelStyle: .alert_text,
                onConfirm: { [weak self, threadData = viewModel.threadData, dependencies = viewModel.dependencies] _ in
                    Result {
                        guard
                            cellViewModel.threadVariant == .community,
                            let roomToken: String = threadData.openGroupRoomToken,
                            let server: String = threadData.openGroupServer,
                            let publicKey: String = threadData.openGroupPublicKey,
                            let capabilities: Set<Capability.Variant> = threadData.openGroupCapabilities,
                            let openGroupServerMessageId: Int64 = cellViewModel.openGroupServerMessageId
                        else { throw CryptoError.invalidAuthentication }
                        
                        return (
                            roomToken,
                            Authentication.community(
                                info: LibSession.OpenGroupCapabilityInfo(
                                    roomToken: roomToken,
                                    server: server,
                                    publicKey: publicKey,
                                    capabilities: capabilities
                                )
                            )
                        )
                    }
                    .publisher
                    .tryFlatMap { (roomToken: String, authMethod: AuthenticationMethod) in
                        try Network.SOGS.preparedUserBanAndDeleteAllMessages(
                            sessionId: cellViewModel.authorId,
                            roomToken: roomToken,
                            authMethod: authMethod,
                            using: dependencies
                        ).send(using: dependencies)
                    }
                    .subscribe(on: DispatchQueue.global(qos: .userInitiated), using: dependencies)
                    .receive(on: DispatchQueue.main, using: dependencies)
                    .sinkUntilComplete(
                        receiveCompletion: { result in
                            DispatchQueue.main.async { [weak self] in
                                switch result {
                                    case .finished:
                                        self?.viewModel.showToast(
                                            text: "banUserBanned".localized(),
                                            backgroundColor: .backgroundSecondary,
                                            inset: (self?.inputAccessoryView?.frame.height ?? Values.mediumSpacing) + Values.smallSpacing
                                        )
                                    case .failure:
                                        self?.viewModel.showToast(
                                            text: "banErrorFailed".localized(),
                                            backgroundColor: .backgroundSecondary,
                                            inset: (self?.inputAccessoryView?.frame.height ?? Values.mediumSpacing) + Values.smallSpacing
                                        )
                                }
                                completion?()
                            }
                        }
                    )
                    
                    self?.becomeFirstResponder()
                },
                afterClosed: { [weak self] in
                    self?.becomeFirstResponder()
                }
            )
        )
        self.present(modal, animated: true)
    }

    // MARK: - VoiceMessageRecordingViewDelegate

    func startVoiceMessageRecording() {
        // Request permission if needed
        Permissions.requestMicrophonePermissionIfNeeded(using: viewModel.dependencies) { [weak self] in
            DispatchQueue.main.async {
                self?.cancelVoiceMessageRecording()
            }
        }
        
        // Keep screen on
        UIApplication.shared.isIdleTimerDisabled = false
        guard Permissions.microphone == .granted else { return }
        
        // Cancel any current audio playback
        self.viewModel.stopAudio()
        
        // Create URL
        let currentOffsetTimestamp: Int64 = viewModel.dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
        let directory: String = viewModel.dependencies[singleton: .fileManager].temporaryDirectory
        let fileName: String = "\(currentOffsetTimestamp).m4a" // stringlint:ignore
        let url: URL = URL(fileURLWithPath: directory).appendingPathComponent(fileName)
        
        // Set up audio session
        let isConfigured = (SessionEnvironment.shared?.audioSession.startAudioActivity(recordVoiceMessageActivity) == true)
        guard isConfigured else {
            return cancelVoiceMessageRecording()
        }
        
        // Set up audio recorder
        let audioRecorder: AVAudioRecorder
        do {
            audioRecorder = try AVAudioRecorder(
                url: url,
                settings: [
                    AVFormatIDKey: NSNumber(value: kAudioFormatMPEG4AAC),
                    AVSampleRateKey: NSNumber(value: 44100),
                    AVNumberOfChannelsKey: NSNumber(value: 2),
                    AVEncoderBitRateKey: NSNumber(value: 128 * 1024)
                ]
            )
            audioRecorder.isMeteringEnabled = true
            self.audioRecorder = audioRecorder
        }
        catch {
            Log.error(.conversation, "Couldn't start audio recording due to error: \(error).")
            return cancelVoiceMessageRecording()
        }
        
        // Limit voice messages to a minute
        audioTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: false, block: { [weak self] _ in
            self?.snInputView.hideVoiceMessageUI()
            self?.endVoiceMessageRecording()
        })
        
        // Prepare audio recorder and start recording
        let successfullyPrepared: Bool = audioRecorder.prepareToRecord()
        let startedRecording: Bool = (successfullyPrepared && audioRecorder.record())
        
        
        guard successfullyPrepared && startedRecording else {
            Log.error(.conversation, (successfullyPrepared ? "Couldn't record audio." : "Couldn't prepare audio recorder."))
            
            // Dispatch to the next run loop to avoid
            DispatchQueue.main.async {
                let modal: ConfirmationModal = ConfirmationModal(
                    targetView: self.view,
                    info: ConfirmationModal.Info(
                        title: "theError".localized(),
                        body: .text("audioUnableToRecord".localized()),
                        cancelTitle: "okay".localized(),
                        cancelStyle: .alert_text
                    )
                )
                self.present(modal, animated: true)
            }
            
            return cancelVoiceMessageRecording()
        }
    }

    func endVoiceMessageRecording() {
        UIApplication.shared.isIdleTimerDisabled = true
        
        // Hide the UI
        snInputView.hideVoiceMessageUI()
        
        // Cancel the timer
        audioTimer?.invalidate()
        
        // Check preconditions
        guard let audioRecorder = audioRecorder else { return }
        
        // Get duration
        let duration = audioRecorder.currentTime
        
        // Stop the recording
        stopVoiceMessageRecording()
        
        // Check for user misunderstanding
        guard duration > 1 else {
            self.audioRecorder = nil
            
            let modal: ConfirmationModal = ConfirmationModal(
                targetView: self.view,
                info: ConfirmationModal.Info(
                    title: "messageVoice".localized(),
                    body: .text("messageVoiceErrorShort".localized()),
                    cancelTitle: "okay".localized(),
                    cancelStyle: .alert_text
                )
            )
            self.present(modal, animated: true)
            return
        }
        
        // Get data
        let fileName = ("messageVoice".localized() as NSString)
            .appendingPathExtension("m4a") // stringlint:ignore
        let dataSourceOrNil = DataSourcePath(fileUrl: audioRecorder.url, sourceFilename: fileName, shouldDeleteOnDeinit: true, using: viewModel.dependencies)
        self.audioRecorder = nil
        
        guard let dataSource = dataSourceOrNil else {
            return Log.error(.conversation, "Couldn't load recorded data.")
        }
        
        let attachment = SignalAttachment.voiceMessageAttachment(dataSource: dataSource, type: .mpeg4Audio, using: viewModel.dependencies)
        
        guard !attachment.hasError else {
            return showErrorAlert(for: attachment)
        }
        
        // Send attachment
        sendMessage(text: "", attachments: [attachment])
    }

    func cancelVoiceMessageRecording() {
        snInputView.hideVoiceMessageUI()
        audioTimer?.invalidate()
        stopVoiceMessageRecording()
        audioRecorder = nil
    }

    func stopVoiceMessageRecording() {
        audioRecorder?.stop()
        SessionEnvironment.shared?.audioSession.endAudioActivity(recordVoiceMessageActivity)
    }
    
    // MARK: - Data Extraction Notifications
    
    func sendDataExtraction(kind: DataExtractionNotification.Kind) {
        // Only send screenshot notifications to one-to-one conversations
        guard self.viewModel.threadData.threadVariant == .contact else { return }
        
        let threadId: String = self.viewModel.threadData.threadId
        let threadVariant: SessionThread.Variant = self.viewModel.threadData.threadVariant
        
        viewModel.dependencies[singleton: .storage].writeAsync { [dependencies = viewModel.dependencies] db in
            try MessageSender.send(
                db,
                message: DataExtractionNotification(
                    kind: kind,
                    sentTimestampMs: dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
                )
                .with(DisappearingMessagesConfiguration
                    .fetchOne(db, id: threadId)?
                    .forcedWithDisappearAfterReadIfNeeded()
                ),
                interactionId: nil,
                threadId: threadId,
                threadVariant: threadVariant,
                using: dependencies
            )
        }
    }

    // MARK: - Convenience
    
    func showErrorAlert(for attachment: SignalAttachment) {
        DispatchQueue.main.async { [weak self] in
            let modal: ConfirmationModal = ConfirmationModal(
                targetView: self?.view,
                info: ConfirmationModal.Info(
                    title: "attachmentsErrorSending".localized(),
                    body: .text(attachment.localizedErrorDescription ?? SignalAttachment.missingDataErrorMessage),
                    cancelTitle: "okay".localized(),
                    cancelStyle: .alert_text
                )
            )
            self?.present(modal, animated: true)
        }
    }
}

// MARK: - UIDocumentInteractionControllerDelegate

extension ConversationVC: UIDocumentInteractionControllerDelegate {
    func documentInteractionControllerViewControllerForPreview(_ controller: UIDocumentInteractionController) -> UIViewController {
        return self
    }
    
    public func documentInteractionControllerDidEndPreview(_ controller: UIDocumentInteractionController) {
        guard let temporaryFileUrl: URL = controller.url else { return }
        
        /// Now that we are finished with it we want to remove the temporary file (just to be safe ensure that it starts with the
        /// `temporaryDirectory` so we don't accidentally delete a proper file if logic elsewhere changes)
        if temporaryFileUrl.path.starts(with: viewModel.dependencies[singleton: .fileManager].temporaryDirectory) {
            try? viewModel.dependencies[singleton: .fileManager].removeItem(atPath: temporaryFileUrl.path)
        }
    }
}

// MARK: - Message Request Actions

extension ConversationVC {
    fileprivate func approveMessageRequestIfNeeded(
        for threadId: String,
        threadVariant: SessionThread.Variant,
        displayName: String,
        isDraft: Bool,
        timestampMs: Int64
    ) -> AnyPublisher<Void, Never> {
        let updateNavigationBackStack: () -> Void = {
            // Remove the 'SessionTableViewController<MessageRequestsViewModel>' from the nav hierarchy if present
            DispatchQueue.main.async { [weak self] in
                if
                    let viewControllers: [UIViewController] = self?.navigationController?.viewControllers,
                    let messageRequestsIndex = viewControllers
                        .firstIndex(where: { viewCon -> Bool in
                            (viewCon as? SessionViewModelAccessible)?.viewModelType == MessageRequestsViewModel.self
                        }),
                    messageRequestsIndex > 0
                {
                    var newViewControllers = viewControllers
                    newViewControllers.remove(at: messageRequestsIndex)
                    self?.navigationController?.viewControllers = newViewControllers
                }
            }
        }
        
        switch threadVariant {
            case .contact:
                /// If the contact doesn't exist then we should create it so we can store the `isApproved` state (it'll be updated
                /// with correct profile info if they accept the message request so this shouldn't cause weird behaviours)
                guard
                    let contact: Contact = viewModel.dependencies[singleton: .storage].read({ [dependencies = viewModel.dependencies] db in
                        Contact.fetchOrCreate(db, id: threadId, using: dependencies)
                    }),
                    !contact.isApproved
                else { return Just(()).eraseToAnyPublisher() }
                
                return viewModel.dependencies[singleton: .storage]
                    .writePublisher { [dependencies = viewModel.dependencies] db in
                        /// If this isn't a draft thread (ie. sending a message request) then send a `messageRequestResponse`
                        /// back to the sender (this allows the sender to know that they have been approved and can now use this
                        /// contact in closed groups)
                        if !isDraft {
                            _ = try? Interaction(
                                threadId: threadId,
                                threadVariant: threadVariant,
                                authorId: dependencies[cache: .general].sessionId.hexString,
                                variant: .infoMessageRequestAccepted,
                                body: "messageRequestYouHaveAccepted"
                                    .put(key: "name", value: displayName)
                                    .localized(),
                                timestampMs: timestampMs,
                                using: dependencies
                            ).inserted(db)
                            
                            try MessageSender.send(
                                db,
                                message: MessageRequestResponse(
                                    isApproved: true,
                                    sentTimestampMs: UInt64(timestampMs)
                                ),
                                interactionId: nil,
                                threadId: threadId,
                                threadVariant: threadVariant,
                                using: dependencies
                            )
                        }
                        
                        // Default 'didApproveMe' to true for the person approving the message request
                        let updatedDidApproveMe: Bool = (contact.didApproveMe || !isDraft)
                        try contact.upsert(db)
                        try Contact
                            .filter(id: contact.id)
                            .updateAllAndConfig(
                                db,
                                Contact.Columns.isApproved.set(to: true),
                                Contact.Columns.didApproveMe.set(to: updatedDidApproveMe),
                                using: dependencies
                            )
                        db.addContactEvent(id: contact.id, change: .isApproved(true))
                        db.addContactEvent(id: contact.id, change: .didApproveMe(updatedDidApproveMe))
                        db.addEvent(contact.id, forKey: .messageRequestAccepted)
                    }
                    .map { _ in () }
                    .catch { _ in Just(()).eraseToAnyPublisher() }
                    .handleEvents(
                        receiveOutput: { _ in
                            // Update the UI
                            updateNavigationBackStack()
                        }
                    )
                    .eraseToAnyPublisher()
                
            case .group:
                // If the group is not in the invited state then don't bother doing anything
                guard
                    let group: ClosedGroup = viewModel.dependencies[singleton: .storage].read({ db in
                        try ClosedGroup.fetchOne(db, id: threadId)
                    }),
                    group.invited == true
                else { return Just(()).eraseToAnyPublisher() }
                
                return viewModel.dependencies[singleton: .storage]
                    .writePublisher { [dependencies = viewModel.dependencies] db in
                        /// Remove any existing `infoGroupInfoInvited` interactions from the group (don't want to have a
                        /// duplicate one from inside the group history)
                        try Interaction.deleteWhere(
                            db,
                            .filter(Interaction.Columns.threadId == group.id),
                            .filter(Interaction.Columns.variant == Interaction.Variant.infoGroupInfoInvited)
                        )
                        
                        /// Optimistically insert a `standard` member for the current user in this group (it'll be update to the correct
                        /// one once we receive the first `GROUP_MEMBERS` config message but adding it here means the `canWrite`
                        /// state of the group will continue to be `true` while we wait on the initial poll to get back)
                        try GroupMember(
                            groupId: group.id,
                            profileId: dependencies[cache: .general].sessionId.hexString,
                            role: .standard,
                            roleStatus: .accepted,
                            isHidden: false
                        ).upsert(db)
                        
                        /// If this isn't a draft thread (ie. sending a message request) and the user is not an admin then schedule
                        /// sending a `GroupUpdateInviteResponseMessage` to the group (this allows other members to
                        /// know that the user has joined the group)
                        if !isDraft && group.groupIdentityPrivateKey == nil {
                            try MessageSender.send(
                                db,
                                message: GroupUpdateInviteResponseMessage(
                                    isApproved: true,
                                    sentTimestampMs: UInt64(timestampMs)
                                ),
                                interactionId: nil,
                                threadId: threadId,
                                threadVariant: threadVariant,
                                using: dependencies
                            )
                        }
                        
                        /// Actually trigger the approval
                        try ClosedGroup.approveGroupIfNeeded(
                            db,
                            group: group,
                            using: dependencies
                        )
                    }
                    .map { _ in () }
                    .catch { _ in Just(()).eraseToAnyPublisher() }
                    .handleEvents(
                        receiveOutput: { _ in
                            // Update the UI
                            updateNavigationBackStack()
                        }
                    )
                    .eraseToAnyPublisher()
                
            default: return Just(()).eraseToAnyPublisher()
        }
    }

    func acceptMessageRequest() {
        approveMessageRequestIfNeeded(
            for: self.viewModel.threadData.threadId,
            threadVariant: self.viewModel.threadData.threadVariant,
            displayName: self.viewModel.threadData.displayName,
            isDraft: (self.viewModel.threadData.threadIsDraft == true),
            timestampMs: viewModel.dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
        ).sinkUntilComplete()
    }

    func declineMessageRequest() {
        let actions: [UIContextualAction]? = UIContextualAction.generateSwipeActions(
            [.delete],
            for: .trailing,
            indexPath: IndexPath(row: 0, section: 0),
            tableView: self.tableView,
            threadViewModel: self.viewModel.threadData,
            viewController: self, 
            navigatableStateHolder: nil,
            using: viewModel.dependencies
        )
        
        guard let action: UIContextualAction = actions?.first else { return }
        
        action.handler(action, self.view, { [weak self] didConfirm in
            guard didConfirm else { return }
            
            self?.stopObservingChanges()
            
            DispatchQueue.main.async {
                self?.navigationController?.popViewController(animated: true)
            }
        })
    }
    
    func blockMessageRequest() {
        let actions: [UIContextualAction]? = UIContextualAction.generateSwipeActions(
            [.block],
            for: .trailing,
            indexPath: IndexPath(row: 0, section: 0),
            tableView: self.tableView,
            threadViewModel: self.viewModel.threadData,
            viewController: self,
            navigatableStateHolder: nil,
            using: viewModel.dependencies
        )
        
        guard let action: UIContextualAction = actions?.first else { return }
        
        action.handler(action, self.view, { [weak self] didConfirm in
            guard didConfirm else { return }
            
            self?.stopObservingChanges()
            
            DispatchQueue.main.async {
                self?.navigationController?.popViewController(animated: true)
            }
        })
    }
}

// MARK: - Legacy Group Actions

extension ConversationVC {
    @objc public func recreateLegacyGroupTapped() {
        let threadId: String = self.viewModel.threadData.threadId
        let closedGroupName: String? = self.viewModel.threadData.closedGroupName
        let confirmationModal: ConfirmationModal = ConfirmationModal(
            info: ConfirmationModal.Info(
                title: "recreateGroup".localized(),
                body: .text("legacyGroupChatHistory".localized()),
                confirmTitle: "theContinue".localized(),
                confirmStyle: .danger,
                cancelStyle: .alert_text
            ) { [weak self, dependencies = viewModel.dependencies] _ in
                let groupMemberProfileIds: [String] = dependencies[singleton: .storage]
                    .read { db in
                        try GroupMember
                            .select(.profileId)
                            .filter(GroupMember.Columns.groupId == threadId)
                            .asRequest(of: String.self)
                            .fetchAll(db)
                    }
                    .defaulting(to: [])
                let currentUserSessionId: SessionId = dependencies[cache: .general].sessionId
                let viewController: NewClosedGroupVC = NewClosedGroupVC(
                    hideCloseButton: true,
                    prefilledName: closedGroupName,
                    preselectedContactIds: groupMemberProfileIds
                        .filter { $0 != currentUserSessionId.hexString },
                    using: dependencies
                )
                
                // FIXME: Remove this when we can (it's very fragile)
                /// There isn't current a way to animate the change of the `UINavigationBar` background color so instead we
                /// insert this `colorAnimationView` on top of the internal `UIBarBackground` and fade it in/out alongside
                /// the push/pop transitions
                ///
                /// **Note:** If we are unable to get the `UIBarBackground` using the below hacks then the navbar will just
                /// keep it's existing color and look a bit odd on the destination screen
                let colorAnimationView: UIView = UIView(
                    frame: self?.navigationController?.navigationBar.bounds ?? .zero
                )
                colorAnimationView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                colorAnimationView.themeBackgroundColor = .backgroundSecondary
                colorAnimationView.alpha = 0
                
                if
                    let navigationBar: UINavigationBar = self?.navigationController?.navigationBar,
                    let barBackgroundView: UIView = navigationBar.subviews.first(where: { subview -> Bool in
                        "\(subview)".contains("_UIBarBackground") || (
                            subview.subviews.first is UIImageView &&
                            (subview.subviews.first as? UIImageView)?.image == nil
                        )
                    })
                {
                    barBackgroundView.addSubview(colorAnimationView)
                    
                    viewController.onViewWillAppear = { vc in
                        vc.transitionCoordinator?.animate { _ in
                            colorAnimationView.alpha = 1
                        }
                    }
                    viewController.onViewWillDisappear = { vc in
                        vc.transitionCoordinator?.animate(
                            alongsideTransition: { _ in
                                colorAnimationView.alpha = 0
                            },
                            completion: { _ in
                                colorAnimationView.removeFromSuperview()
                            }
                        )
                    }
                    viewController.onViewDidDisappear = { _ in
                        // If the screen is dismissed without an animation then 'onViewWillDisappear'
                        // won't be called so we need to clean up
                        colorAnimationView.removeFromSuperview()
                    }
                }
                self?.navigationController?.pushViewController(viewController, animated: true)
            }
        )
        
        self.navigationController?.present(confirmationModal, animated: true, completion: nil)
    }
}

// MARK: - MediaPresentationContextProvider

extension ConversationVC: MediaPresentationContextProvider {
    func mediaPresentationContext(mediaId: String, in coordinateSpace: UICoordinateSpace) -> MediaPresentationContext? {
        // Note: According to Apple's docs the 'indexPathsForVisibleRows' method returns an
        // unsorted array which means we can't use it to determine the desired 'visibleCell'
        // we are after, due to this we will need to iterate all of the visible cells to find
        // the one we want
        let maybeMessageCell: VisibleMessageCell? = tableView.visibleCells
            .first { cell -> Bool in
                ((cell as? VisibleMessageCell)?
                    .albumView?
                    .itemViews
                    .contains(where: { mediaView in
                        mediaView.attachment.id == mediaId
                    }))
                    .defaulting(to: false)
            }
            .map { $0 as? VisibleMessageCell }
        let maybeTargetView: MediaView? = maybeMessageCell?
            .albumView?
            .itemViews
            .first(where: { $0.attachment.id == mediaId })
        
        guard
            let messageCell: VisibleMessageCell = maybeMessageCell,
            let targetView: MediaView = maybeTargetView,
            let mediaSuperview: UIView = targetView.superview
        else { return nil }

        let cornerRadius: CGFloat
        let cornerMask: CACornerMask
        let presentationFrame: CGRect = coordinateSpace.convert(targetView.frame, from: mediaSuperview)
        let frameInBubble: CGRect = messageCell.bubbleView.convert(targetView.frame, from: mediaSuperview)

        if messageCell.bubbleView.bounds == targetView.bounds {
            cornerRadius = messageCell.bubbleView.layer.cornerRadius
            cornerMask = messageCell.bubbleView.layer.maskedCorners
        }
        else {
            // If the frames don't match then assume it's either multiple images or there is a caption
            // and determine which corners need to be rounded
            cornerRadius = messageCell.bubbleView.layer.cornerRadius

            var newCornerMask = CACornerMask()
            let cellMaskedCorners: CACornerMask = messageCell.bubbleView.layer.maskedCorners

            if
                cellMaskedCorners.contains(.layerMinXMinYCorner) &&
                    frameInBubble.minX < CGFloat.leastNonzeroMagnitude &&
                    frameInBubble.minY < CGFloat.leastNonzeroMagnitude
            {
                newCornerMask.insert(.layerMinXMinYCorner)
            }

            if
                cellMaskedCorners.contains(.layerMaxXMinYCorner) &&
                abs(frameInBubble.maxX - messageCell.bubbleView.bounds.width) < CGFloat.leastNonzeroMagnitude &&
                    frameInBubble.minY < CGFloat.leastNonzeroMagnitude
            {
                newCornerMask.insert(.layerMaxXMinYCorner)
            }

            if
                cellMaskedCorners.contains(.layerMinXMaxYCorner) &&
                    frameInBubble.minX < CGFloat.leastNonzeroMagnitude &&
                abs(frameInBubble.maxY - messageCell.bubbleView.bounds.height) < CGFloat.leastNonzeroMagnitude
            {
                newCornerMask.insert(.layerMinXMaxYCorner)
            }

            if
                cellMaskedCorners.contains(.layerMaxXMaxYCorner) &&
                abs(frameInBubble.maxX - messageCell.bubbleView.bounds.width) < CGFloat.leastNonzeroMagnitude &&
                abs(frameInBubble.maxY - messageCell.bubbleView.bounds.height) < CGFloat.leastNonzeroMagnitude
            {
                newCornerMask.insert(.layerMaxXMaxYCorner)
            }

            cornerMask = newCornerMask
        }
        
        return MediaPresentationContext(
            mediaView: targetView.imageView,
            presentationFrame: presentationFrame,
            cornerRadius: cornerRadius,
            cornerMask: cornerMask
        )
    }

    func snapshotOverlayView(in coordinateSpace: UICoordinateSpace) -> (UIView, CGRect)? {
        return self.navigationController?.navigationBar.generateSnapshot(in: coordinateSpace)
    }
}
