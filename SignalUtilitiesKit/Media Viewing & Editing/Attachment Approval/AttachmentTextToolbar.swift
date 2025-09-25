//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.

import Foundation
import UIKit
import Lucide
import SessionUIKit
import SessionUtilitiesKit
import Combine

// Coincides with Android's max text message length
let kMaxMessageBodyCharacterCount = 2000

protocol AttachmentTextToolbarDelegate: AnyObject {
    func attachmentTextToolbarDidTapSend(_ attachmentTextToolbar: AttachmentTextToolbar)
    func attachmentTextToolbarDidChange(_ attachmentTextToolbar: AttachmentTextToolbar)
    func attachmentTextToolBarDidTapCharacterLimitLabel(_ attachmentTextToolbar: AttachmentTextToolbar)
}

// MARK: -

class AttachmentTextToolbar: UIView, UITextViewDelegate {
    
    private static let thresholdForCharacterLimit: Int = 200
    
    // MARK: - Variables
    
    private var disposables: Set<AnyCancellable> = Set()
    public weak var delegate: AttachmentTextToolbarDelegate?
    private let dependencies: Dependencies
    private var sessionProState: SessionProManagerType?

    var text: String? {
        get { inputTextView.text }
        set { inputTextView.text = newValue }
    }

    // MARK: - UI
    
    private var bottomStackView: UIStackView?
    
    private lazy var sendButton: InputViewButton = {
        let sendIcon = Lucide.image(icon: .arrowUp, size: IconSize.medium.size)
        
        let result = InputViewButton(icon: sendIcon, isSendButton: true, delegate: self)
        result.accessibilityIdentifier = "Send message button"
        result.accessibilityLabel = "Send message button"
        result.isAccessibilityElement = true
        
        return result
    }()
    
    private lazy var inputTextView: InputTextView = {
        // HACK: When restoring a draft the input text view won't have a frame yet, and therefore it won't
        // be able to calculate what size it should be to accommodate the draft text. As a workaround, we
        // just calculate the max width that the input text view is allowed to be and pass it in. See
        // setUpViewHierarchy() for why these values are the way they are.
        let adjustment = (InputViewButton.expandedSize - InputViewButton.size) / 2
        let maxWidth = UIScreen.main.bounds.width - InputViewButton.expandedSize - Values.smallSpacing - 2 * (Values.mediumSpacing - adjustment)
        let result = InputTextView(delegate: self, maxWidth: maxWidth)
        result.accessibilityLabel = "contentDescriptionMessageComposition".localized()
        result.accessibilityIdentifier = "Message input box"
        result.isAccessibilityElement = true
        
        return result
    }()
    
    private lazy var proStackView: UIStackView = {
        let result = UIStackView(arrangedSubviews: [ characterLimitLabel, sessionProBadge ])
        result.axis = .vertical
        result.spacing = Values.verySmallSpacing
        result.alignment = .center
        result.addGestureRecognizer(characterLimitLabelTapGestureRecognizer)
        result.alpha = 0
        
        return result
    }()
    private lazy var characterLimitLabelTapGestureRecognizer: UITapGestureRecognizer = {
        let result: UITapGestureRecognizer = UITapGestureRecognizer()
        result.addTarget(self, action: #selector(characterLimitLabelTapped))
        result.isEnabled = false
        
        return result
    }()
    
    private lazy var characterLimitLabel: UILabel = {
        let label: UILabel = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: Values.smallFontSize)
        label.themeTextColor = .textPrimary
        label.textAlignment = .center
        
        return label
    }()
    
    private lazy var sessionProBadge: SessionProBadge = {
        let result: SessionProBadge = SessionProBadge(size: .small)
        result.isHidden = !dependencies[feature: .sessionProEnabled] || dependencies[cache: .libSession].isSessionPro
        
        return result
    }()

    // MARK: - Initializers

    init(delegate: AttachmentTextToolbarDelegate, using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.delegate = delegate
        self.sessionProState = dependencies[singleton: .sessionProState]
        
        super.init(frame: CGRect.zero)
        
        setUpViewHierarchy()
        
        self.sessionProState?.isSessionProPublisher
            .subscribe(on: DispatchQueue.main)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveValue: { [weak self] isPro in
                    self?.sessionProBadge.isHidden = isPro
                    self?.updateNumberOfCharactersLeft((self?.inputTextView.text ?? ""))
                }
            )
            .store(in: &disposables)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setUpViewHierarchy() {
        autoresizingMask = .flexibleHeight
        
        // Background & blur
        let backgroundView = UIView()
        backgroundView.themeBackgroundColor = .clear
        addSubview(backgroundView)
        backgroundView.pin(to: self)
        
        // Separator
        let separator = UIView()
        separator.themeBackgroundColor = .borderSeparator
        separator.set(.height, to: Values.separatorThickness)
        addSubview(separator)
        separator.pin([ UIView.HorizontalEdge.leading, UIView.VerticalEdge.top, UIView.HorizontalEdge.trailing ], to: self)
        
        // Bottom stack view
        let bottomStackView = UIStackView(arrangedSubviews: [ inputTextView, container(for: sendButton) ])
        bottomStackView.axis = .horizontal
        bottomStackView.spacing = Values.smallSpacing
        bottomStackView.alignment = .center
        self.bottomStackView = bottomStackView
        
        // Main stack view
        let mainStackView = UIStackView(arrangedSubviews: [ bottomStackView ])
        mainStackView.axis = .vertical
        mainStackView.isLayoutMarginsRelativeArrangement = true
        
        let adjustment = (InputViewButton.expandedSize - InputViewButton.size) / 2
        mainStackView.layoutMargins = UIEdgeInsets(top: 2, leading: Values.mediumSpacing - adjustment, bottom: 2, trailing: Values.mediumSpacing - adjustment)
        addSubview(mainStackView)
        mainStackView.pin(.top, to: .bottom, of: separator)
        mainStackView.pin([ UIView.HorizontalEdge.leading, UIView.HorizontalEdge.trailing ], to: self)
        mainStackView.pin(.bottom, to: .bottom, of: self)
        
        // Pro stack view
        addSubview(proStackView)
        proStackView.pin(.bottom, to: .bottom, of: inputTextView)
        proStackView.center(.horizontal, in: sendButton)
    }
    
    func updateNumberOfCharactersLeft(_ text: String) {
        let numberOfCharactersLeft: Int = LibSession.numberOfCharactersLeft(
            for: text.trimmingCharacters(in: .whitespacesAndNewlines),
            isSessionPro: dependencies[cache: .libSession].isSessionPro
        )
        characterLimitLabel.text = "\(numberOfCharactersLeft.formatted(format: .abbreviated(decimalPlaces: 1)))"
        characterLimitLabel.themeTextColor = (numberOfCharactersLeft < 0) ? .danger : .textPrimary
        proStackView.alpha = (numberOfCharactersLeft <= Self.thresholdForCharacterLimit) ? 1 : 0
        characterLimitLabelTapGestureRecognizer.isEnabled = (numberOfCharactersLeft < Self.thresholdForCharacterLimit)
    }
    
    // MARK: - Action
    
    @objc private func characterLimitLabelTapped() {
        delegate?.attachmentTextToolBarDidTapCharacterLimitLabel(self)
    }
    
    // MARK: - Convenience
    
    private func container(for button: InputViewButton) -> UIView {
        let result: UIView = UIView()
        result.addSubview(button)
        result.set(.width, to: InputViewButton.expandedSize)
        result.set(.height, to: InputViewButton.expandedSize)
        button.center(in: result)
        
        return result
    }
}

extension AttachmentTextToolbar: InputViewButtonDelegate {
    func handleInputViewButtonTapped(_ inputViewButton: InputViewButton) {
        delegate?.attachmentTextToolbarDidTapSend(self)
    }
    func handleInputViewButtonLongPressBegan(_ inputViewButton: InputViewButton?) {}
    func handleInputViewButtonLongPressMoved(_ inputViewButton: InputViewButton, with touch: UITouch?) {}
    func handleInputViewButtonLongPressEnded(_ inputViewButton: InputViewButton, with touch: UITouch?) {}
}

extension AttachmentTextToolbar: InputTextViewDelegate {
    func inputTextViewDidChangeSize(_ inputTextView: InputTextView) {
        invalidateIntrinsicContentSize()
        self.bottomStackView?.alignment = (inputTextView.contentSize.height > inputTextView.minHeight) ? .top : .center
    }
    
    func inputTextViewDidChangeContent(_ inputTextView: InputTextView) {
        updateNumberOfCharactersLeft(text ?? "")
        delegate?.attachmentTextToolbarDidChange(self)
    }
    
    func didPasteImageFromPasteboard(_ inputTextView: InputTextView, image: UIImage) {
        
    }
}
