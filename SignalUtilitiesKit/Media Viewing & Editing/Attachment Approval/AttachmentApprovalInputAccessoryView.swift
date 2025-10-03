// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import UIKit
import SessionUIKit
import SessionUtilitiesKit

protocol AttachmentApprovalInputAccessoryViewDelegate: AnyObject {
    func attachmentApprovalInputUpdateMediaRail()
}

// MARK: -

class AttachmentApprovalInputAccessoryView: UIView {

    weak var delegate: AttachmentApprovalInputAccessoryViewDelegate?

    let attachmentTextToolbar: AttachmentTextToolbar
    let galleryRailView: GalleryRailView

    var isEditingMediaMessage: Bool {
        return attachmentTextToolbar.inputView?.isFirstResponder ?? false
    }

    private var currentAttachmentItem: PendingAttachmentRailItem?

    let kGalleryRailViewHeight: CGFloat = 72

    required init(delegate: AttachmentTextToolbarDelegate, using dependencies: Dependencies) {
        attachmentTextToolbar = AttachmentTextToolbar(delegate: delegate, using: dependencies)

        galleryRailView = GalleryRailView()
        galleryRailView.scrollFocusMode = .keepWithinBounds
        galleryRailView.set(.height, to: kGalleryRailViewHeight)

        super.init(frame: .zero)

        createContents()
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func createContents() {
        // Specifying auto-resizing mask and an intrinsic content size allows proper
        // sizing when used as an input accessory view.
        self.autoresizingMask = .flexibleHeight
        self.translatesAutoresizingMaskIntoConstraints = false
        self.themeBackgroundColor = .clear

        preservesSuperviewLayoutMargins = true

        // Use a background view that extends below the keyboard to avoid animation glitches.
        let backgroundView = UIView()
        backgroundView.themeBackgroundColor = .backgroundPrimary
        addSubview(backgroundView)
        backgroundView.pin(to: self)
        
        // Separator
        let separator = UIView.separator()
        addSubview(separator)
        separator.pin(.top, to: .top, of: self)
        separator.pin(.leading, to: .leading, of: self)
        separator.pin(.trailing, to: .trailing, of: self)

        let stackView = UIStackView(arrangedSubviews: [galleryRailView, attachmentTextToolbar])
        stackView.axis = .vertical

        addSubview(stackView)
        stackView.pin(.top, to: .top, of: self)
        stackView.pin(.leading, to: .leading, of: self)
        stackView.pin(.trailing, to: .trailing, of: self)
        // We pin to the superview's _margin_.  Otherwise the notch breaks
        // the layout if you hide the keyboard in the simulator (or if the
        // user uses an external keyboard).
        stackView.pin(.bottom, toMargin: .bottom, of: self)
        
        let galleryRailBlockingView: UIView = UIView()
        galleryRailBlockingView.themeBackgroundColor = .backgroundPrimary
        stackView.addSubview(galleryRailBlockingView)
        galleryRailBlockingView.pin(.top, to: .bottom, of: attachmentTextToolbar)
        galleryRailBlockingView.pin(.left, to: .left, of: stackView)
        galleryRailBlockingView.pin(.right, to: .right, of: stackView)
        galleryRailBlockingView.pin(.bottom, to: .bottom, of: stackView)
    }

    // MARK: 

    private var shouldHideControls = false

    private func updateFirstResponder() {
        if (shouldHideControls) {
            attachmentTextToolbar.inputView?.resignFirstResponder()
        }
    }

    public func update(currentAttachmentItem: PendingAttachmentRailItem?, shouldHideControls: Bool) {
        self.currentAttachmentItem = currentAttachmentItem
        self.shouldHideControls = shouldHideControls

        updateFirstResponder()
    }

    // MARK: 

    override var intrinsicContentSize: CGSize {
        get {
            // Since we have `self.autoresizingMask = UIViewAutoresizingFlexibleHeight`, we must specify
            // an intrinsicContentSize. Specifying CGSize.zero causes the height to be determined by autolayout.
            return CGSize.zero
        }
    }

    public var hasFirstResponder: Bool {
        return (isFirstResponder || attachmentTextToolbar.inputView?.isFirstResponder ?? false)
    }
}
