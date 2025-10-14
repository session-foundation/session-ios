// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import UIKit
import SessionUIKit
import SessionUtilitiesKit

protocol AttachmentApprovalInputAccessoryViewDelegate: AnyObject {
    func attachmentApprovalInputUpdateMediaRail()
}

protocol AttachmentApprovalInputAccessoryViewDataSource: AnyObject {
    func attachmentApprovalQouteAccessoryView(onDeleteHandler handler: @escaping () -> Void) -> UIView?
}

// MARK: -

class AttachmentApprovalInputAccessoryView: UIView {

    weak var delegate: AttachmentApprovalInputAccessoryViewDelegate?
    weak var dataSource: AttachmentApprovalInputAccessoryViewDataSource?

    let attachmentTextToolbar: AttachmentTextToolbar
    let galleryRailView: GalleryRailView
    private lazy var additionalContentContainer = UIView()

    var isEditingMediaMessage: Bool {
        return attachmentTextToolbar.inputView?.isFirstResponder ?? false
    }

    private var currentAttachmentItem: SignalAttachmentItem?
    
    let kGalleryRailViewHeight: CGFloat = 72

    required init(delegate: AttachmentTextToolbarDelegate, dataSource: AttachmentApprovalInputAccessoryViewDataSource?, using dependencies: Dependencies) {
        attachmentTextToolbar = AttachmentTextToolbar(delegate: delegate, using: dependencies)
        self.dataSource = dataSource

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

        let stackView = UIStackView(arrangedSubviews: [
            galleryRailView,
            additionalContentContainer,
            attachmentTextToolbar
        ])
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
        
        setupQuoteAccessoryViewIfAny()
    }

    // MARK: 

    private var shouldHideControls = false

    private func updateFirstResponder() {
        if (shouldHideControls) {
            attachmentTextToolbar.inputView?.resignFirstResponder()
        }
    }

    public func update(currentAttachmentItem: SignalAttachmentItem?, shouldHideControls: Bool) {
        self.currentAttachmentItem = currentAttachmentItem
        self.shouldHideControls = shouldHideControls

        updateFirstResponder()
    }
    
    // MARK: - Additional accessory view
    private func setupQuoteAccessoryViewIfAny() {
        additionalContentContainer.subviews.forEach { $0.removeFromSuperview() }

        let view = dataSource?.attachmentApprovalQouteAccessoryView { [weak self] in
            self?.additionalContentContainer.subviews.forEach { $0.removeFromSuperview() }
        }

        guard let quoteView = view else { return }
        
        let hInset: CGFloat = 6 // Slight visual adjustment

        additionalContentContainer.addSubview(quoteView)
        quoteView.pin(.leading, to: .leading, of: additionalContentContainer, withInset: hInset)
        quoteView.pin(.top, to: .top, of: additionalContentContainer, withInset: 12)
        quoteView.pin(.trailing, to: .trailing, of: additionalContentContainer, withInset: -hInset)
        quoteView.pin(.bottom, to: .bottom, of: additionalContentContainer, withInset: -6)
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
