//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.

import Foundation
import UIKit
import SessionUIKit
import SessionUtilitiesKit

// Coincides with Android's max text message length
let kMaxMessageBodyCharacterCount = 2000

protocol AttachmentTextToolbarDelegate: AnyObject {
    func attachmentTextToolbarDidTapSend(_ attachmentTextToolbar: AttachmentTextToolbar)
    func attachmentTextToolbarDidBeginEditing(_ attachmentTextToolbar: AttachmentTextToolbar)
    func attachmentTextToolbarDidEndEditing(_ attachmentTextToolbar: AttachmentTextToolbar)
    func attachmentTextToolbarDidChange(_ attachmentTextToolbar: AttachmentTextToolbar)
}

// MARK: -

class AttachmentTextToolbar: UIView, UITextViewDelegate {

    weak var attachmentTextToolbarDelegate: AttachmentTextToolbarDelegate?

    var messageText: String? {
        get { return textView.text }

        set {
            textView.text = newValue
            updatePlaceholderTextViewVisibility()
        }
    }

    // Layout Constants
    
    static let kToolbarMargin: CGFloat = 8
    static let kMinTextViewHeight: CGFloat = 40
    var maxTextViewHeight: CGFloat {
        // About ~4 lines in portrait and ~3 lines in landscape.
        // Otherwise we risk obscuring too much of the content.
        return UIDevice.current.orientation.isPortrait ? 160 : 100
    }
    var textViewHeightConstraint: NSLayoutConstraint!
    var textViewHeight: CGFloat

    // MARK: - Initializers

    init() {
        self.sendButton = UIButton(type: .system)
        self.textViewHeight = AttachmentTextToolbar.kMinTextViewHeight

        super.init(frame: CGRect.zero)

        // Specifying autorsizing mask and an intrinsic content size allows proper
        // sizing when used as an input accessory view.
        self.autoresizingMask = .flexibleHeight
        self.translatesAutoresizingMaskIntoConstraints = false
        self.themeBackgroundColor = .clear

        textView.delegate = self
        textView.accessibilityIdentifier = "Text input box"
        textView.isAccessibilityElement = true

        let sendTitle = "send".localized()
        sendButton.setTitle(sendTitle, for: .normal)
        sendButton.addTarget(self, action: #selector(didTapSend), for: .touchUpInside)

        sendButton.titleLabel?.font = .boldSystemFont(ofSize: Values.mediumFontSize)
        sendButton.titleLabel?.textAlignment = .center
        sendButton.themeTintColor = .textPrimary
        sendButton.accessibilityIdentifier = "Send button"
        sendButton.isAccessibilityElement = true

        // Increase hit area of send button
        sendButton.contentEdgeInsets = UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)

        let contentView = UIView()
        contentView.addSubview(sendButton)
        contentView.addSubview(textContainer)
        contentView.addSubview(lengthLimitLabel)
        addSubview(contentView)
        contentView.pin(to: self)

        // Layout

        // We have to wrap the toolbar items in a content view because iOS (at least on iOS10.3) assigns the inputAccessoryView.layoutMargins
        // when resigning first responder (verified by auditing with `layoutMarginsDidChange`).
        // The effect of this is that if we were to assign these margins to self.layoutMargins, they'd be blown away if the
        // user dismisses the keyboard, giving the input accessory view a wonky layout.
        contentView.layoutMargins = UIEdgeInsets(
            top: AttachmentTextToolbar.kToolbarMargin,
            left: AttachmentTextToolbar.kToolbarMargin,
            bottom: AttachmentTextToolbar.kToolbarMargin,
            right: AttachmentTextToolbar.kToolbarMargin
        )

        self.textViewHeightConstraint = textView.set(.height, to: AttachmentTextToolbar.kMinTextViewHeight)
        textContainer.pin(.top, toMargin: .top, of: contentView)
        textContainer.pin(.bottom, toMargin: .bottom, of: contentView)
        textContainer.pin(.left, toMargin: .left, of: contentView)

        sendButton.pin(.left, to: .right, of: textContainer, withInset: AttachmentTextToolbar.kToolbarMargin)
        sendButton.pin(.right, toMargin: .right, of: contentView)
        sendButton.pin(.bottom, to: .bottom, of: textContainer, withInset: -3)
        sendButton.setContentHugging(to: .required)
        sendButton.setCompressionResistance(to: .required)

        lengthLimitLabel.pin(.left, toMargin: .left, of: contentView)
        lengthLimitLabel.pin(.right, toMargin: .right, of: contentView)
        lengthLimitLabel.pin(.bottom, to: .top, of: textContainer, withInset: -6)
        lengthLimitLabel.setContentHugging(to: .required)
        lengthLimitLabel.setCompressionResistance(to: .required)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - UIView Overrides

    override var intrinsicContentSize: CGSize {
        get {
            // Since we have `self.autoresizingMask = UIViewAutoresizingFlexibleHeight`, we must specify
            // an intrinsicContentSize. Specifying CGSize.zero causes the height to be determined by autolayout.
            return CGSize.zero
        }
    }

    // MARK: - Subviews

    private let sendButton: UIButton

    private lazy var lengthLimitLabel: UILabel = {
        let lengthLimitLabel = UILabel()

        // Length Limit Label shown when the user inputs too long of a message
        lengthLimitLabel.text = "messageErrorLimit".localized()
        lengthLimitLabel.themeTextColor = .textPrimary
        lengthLimitLabel.textAlignment = .center

        // Add shadow in case overlayed on white content
        lengthLimitLabel.themeShadowColor = .black
        lengthLimitLabel.layer.shadowOffset = .zero
        lengthLimitLabel.layer.shadowOpacity = 0.8
        lengthLimitLabel.layer.shadowRadius = 2.0
        lengthLimitLabel.isHidden = true

        return lengthLimitLabel
    }()

    lazy var textView: UITextView = {
        let textView = buildTextView()

        textView.returnKeyType = .done
        textView.scrollIndicatorInsets = UIEdgeInsets(top: 5, left: 0, bottom: 5, right: 3)

        return textView
    }()

    private lazy var placeholderTextView: UITextView = {
        let placeholderTextView = buildTextView()

        placeholderTextView.text = "message".localized()
        placeholderTextView.isEditable = false

        return placeholderTextView
    }()

    private lazy var textContainer: UIView = {
        let textContainer = UIView()

        textContainer.themeBorderColor = .borderSeparator
        textContainer.layer.borderWidth = Values.separatorThickness
        textContainer.layer.cornerRadius = (AttachmentTextToolbar.kMinTextViewHeight / 2)
        textContainer.clipsToBounds = true

        textContainer.addSubview(placeholderTextView)
        placeholderTextView.pin(to: textContainer)

        textContainer.addSubview(textView)
        textView.pin(to: textContainer)

        return textContainer
    }()

    private func buildTextView() -> UITextView {
        let textView = AttachmentTextView()

        textView.themeBackgroundColor = .clear
        textView.themeTintColor = .textPrimary

        textView.font = .systemFont(ofSize: Values.mediumFontSize)
        textView.themeTextColor = .textPrimary
        textView.showsVerticalScrollIndicator = false
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        
        ThemeManager.onThemeChange(observer: textView) { [weak textView] theme, _ in
            textView?.keyboardAppearance = theme.keyboardAppearance
        }

        return textView
    }

    // MARK: - Actions
    
    @objc func didTapSend() {
        attachmentTextToolbarDelegate?.attachmentTextToolbarDidTapSend(self)
    }

    // MARK: - UITextViewDelegate

    public func textViewDidChange(_ textView: UITextView) {
        updateHeight(textView: textView)
        attachmentTextToolbarDelegate?.attachmentTextToolbarDidChange(self)
    }

    public func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        let existingText: String = textView.text ?? ""
        let proposedText: String = (existingText as NSString).replacingCharacters(in: range, with: text)

        self.lengthLimitLabel.isHidden = true

        // After verifying the byte-length is sufficiently small, verify the character count is within bounds.
        guard proposedText.count < kMaxMessageBodyCharacterCount else {
            Log.debug("[AttachmentTextToolbar] hit attachment message body character count limit")

            self.lengthLimitLabel.isHidden = false

            // `range` represents the section of the existing text we will replace. We can re-use that space.
            let charsAfterDelete: Int = (existingText as NSString).replacingCharacters(in: range, with: "").count

            // Accept as much of the input as we can
            let charBudget: Int = Int(kMaxMessageBodyCharacterCount) - charsAfterDelete
            if charBudget >= 0 {
                let acceptableNewText = String(text.prefix(charBudget))
                textView.text = (existingText as NSString).replacingCharacters(in: range, with: acceptableNewText)
            }

            return false
        }

        // Though we can wrap the text, we don't want to encourage multline captions, plus a "done" button
        // allows the user to get the keyboard out of the way while in the attachment approval view.
        if text == "\n" {   // stringlint:ignore
            textView.resignFirstResponder()
            return false
        }
     
        return true
    }

    public func textViewDidBeginEditing(_ textView: UITextView) {
        attachmentTextToolbarDelegate?.attachmentTextToolbarDidBeginEditing(self)
        updatePlaceholderTextViewVisibility()
    }

    public func textViewDidEndEditing(_ textView: UITextView) {
        attachmentTextToolbarDelegate?.attachmentTextToolbarDidEndEditing(self)
        updatePlaceholderTextViewVisibility()
    }

    // MARK: - Helpers

    func updatePlaceholderTextViewVisibility() {
        let isHidden: Bool = {
            guard !self.textView.isFirstResponder else {
                return true
            }

            guard let text = self.textView.text else {
                return false
            }

            guard text.count > 0 else {
                return false
            }

            return true
        }()

        placeholderTextView.isHidden = isHidden
    }

    private func updateHeight(textView: UITextView) {
        // compute new height assuming width is unchanged
        let currentSize = textView.frame.size
        let newHeight = clampedTextViewHeight(fixedWidth: currentSize.width)

        if newHeight != textViewHeight {
            Log.debug("[AttachmentTextToolbar] TextView height changed: \(textViewHeight) -> \(newHeight)")
            textViewHeight = newHeight
            textViewHeightConstraint?.constant = textViewHeight
            invalidateIntrinsicContentSize()
        }
    }

    private func clampedTextViewHeight(fixedWidth: CGFloat) -> CGFloat {
        let contentSize = textView.sizeThatFits(CGSize(width: fixedWidth, height: CGFloat.greatestFiniteMagnitude))
        return contentSize.height.clamp(AttachmentTextToolbar.kMinTextViewHeight, maxTextViewHeight)
    }
}
