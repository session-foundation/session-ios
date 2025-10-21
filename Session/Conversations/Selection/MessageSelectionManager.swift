// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Lucide
import SessionMessagingKit
import SessionUIKit

protocol SelectionManagerDelegate: ContextMenuActionDelegate {
    func willDeleteMessages(_ messages: [MessageViewModel], completion: @escaping () -> Void)
    func shouldResetSelectionState()
    func shouldShowCopyToast()
    func showInfo(for message: MessageViewModel, withSender sender: UIBarButtonItem)

    var selectedMessages: Set<MessageViewModel> { get }
}

class MessageSelectionManager: NSObject {
    var delegate: SelectionManagerDelegate?
    var selectedMessages: Set<MessageViewModel> {
        delegate?.selectedMessages ?? []
    }
    
    init(delegate: SelectionManagerDelegate) {
        self.delegate = delegate
    }
    
    private func onButtonCreation(icon: UIImage?, accessibilityLabel: String, action: Selector) -> UIBarButtonItem? {
        let result = UIBarButtonItem(
            image: icon,
            style: .plain,
            target: self,
            action: action
        )
        result.accessibilityLabel = accessibilityLabel
        result.isAccessibilityElement = true
        return result
    }

    @MainActor
    func createNavigationActions() -> [UIBarButtonItem] {
        // Create all possible buttons, using selectors pointing to the Manager's methods
        let replyButtonItem = onButtonCreation(
            icon: Lucide.image(
                icon: .reply,
                size: IconSize.medium.size
            ),
            accessibilityLabel: "Reply",
            action: #selector(replySelected)
        )
        let downloadButtonItem = onButtonCreation(
            icon: Lucide.image(
                icon: .download,
                size: IconSize.medium.size
            ),
            accessibilityLabel: "Download",
            action: #selector(saveSelected)
        )
        let copyButtonItem = onButtonCreation(
            icon: Lucide.image(
                icon: .copy,
                size: IconSize.medium.size
            ),
            accessibilityLabel: "Copy",
            action: #selector(copySelected)
        )
        let deleteButtonItem = onButtonCreation(
            icon: Lucide.image(
                icon: .trash2,
                size: IconSize.medium.size
            ),
            accessibilityLabel: "Delete",
            action: #selector(deleteSelected)
        )
        let moreButtonItem = onButtonCreation(
            icon: Lucide.image(
                icon: .ellipsisVertical,
                size: IconSize.medium.size
            ),
            accessibilityLabel: "More",
            action: #selector(moreOptions)
        )
        moreButtonItem?.tag = 99
        
        var showDownload: Bool {
            guard
                selectedMessages.count <= 1,
                selectedMessages.first(where: { $0.attachments != nil }) != nil
            else {
                return false
                
            }
            return true
            
        }
        
        var showReply: Bool {
            return selectedMessages.count <= 1
        }

        var showDelete: Bool { !showDownload }

        var showCopy: Bool {
            guard selectedMessages.count <= 1 else {
                return selectedMessages.contains(where: { $0.cellType == .textOnlyMessage })
            }
            return false
        }

        let items = [
            selectedMessages.count <= 1 ? moreButtonItem : nil,
            showCopy ? copyButtonItem : nil,
            showDelete ? deleteButtonItem : nil,
            showDownload ? downloadButtonItem : nil,
            showReply ? replyButtonItem : nil
        ].compactMap { $0 }
        
        return items
    }
    
    @objc
    func replySelected() {
        guard selectedMessages.count == 1, let message = selectedMessages.first, let delegate = delegate else { return }
        delegate.reply(message) { [weak self] in self?.delegate?.shouldResetSelectionState() }
    }
    
    @objc
    func copySelected() {
        let textMessages = selectedMessages
             .filter { $0.cellType == .textOnlyMessage }
             .sorted { $0.dateForUI < $1.dateForUI }
        
        if textMessages.count == 1, let textMessage = textMessages.first {
            delegate?.copy(textMessage) { [weak self] in self?.delegate?.shouldResetSelectionState() }
        } else if !textMessages.isEmpty {
            let textToCopy = textMessages
                .map { "\($0.dateForUI.formattedForDisplay): \($0.body ?? "")"}
                .joined(separator: "\n")
            
            UIPasteboard.general.string = textToCopy
            
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(0.3 * 1000))) { [weak self] in
                self?.delegate?.shouldShowCopyToast()
            }
            
            delegate?.shouldResetSelectionState()
        }
    }
    
    @objc
    func deleteSelected() {
        delegate?.willDeleteMessages(Array(selectedMessages)) { [weak self] in self?.delegate?.shouldResetSelectionState() }
    }
    
    @objc
    func saveSelected() {
        guard selectedMessages.count == 1, let message = selectedMessages.first else { return }
        delegate?.save(message) { [weak self] in self?.delegate?.shouldResetSelectionState() }
    }
    
    @objc
    func moreOptions(_ sender: UIBarButtonItem) {
        guard let selectedMessage = selectedMessages.first else {
            return
        }
        delegate?.showInfo(for: selectedMessage, withSender: sender)
    }
}
