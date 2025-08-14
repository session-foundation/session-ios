// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit

protocol AppReviewPromptDialogDelegate: AnyObject {
    func willHandlePromptState(_ state: AppReviewPromptState, isPrimary: Bool)
    func didChangePromptState(_ state: AppReviewPromptState)
    func didCloseBeforeReview()
}

class AppReviewPromptDialog: UIView {
    weak var delegate: AppReviewPromptDialogDelegate?
    
    private lazy var closeButton: UIButton = {
        let button = UIButton(type: .custom)
        button.setImage(
            UIImage(named: "X")?
                .withRenderingMode(.alwaysTemplate),
            for: .normal
        )
        button.themeTintColor = .textPrimary
        button.addTarget(self, action: #selector(close), for: UIControl.Event.touchUpInside)
        button.set(.width, to: Values.largeSpacing)
        button.set(.height, to: Values.largeSpacing)
        
       return button
    }()
    
    private lazy var titleLabel: UILabel = {
        let label = UILabel()
        label.textAlignment = .center
        label.numberOfLines = 0
        label.themeTextColor = .textPrimary
        label.font = .systemFont(ofSize: Values.mediumFontSize, weight: .medium)
        return label
    }()
    
    private lazy var messageLabel: UILabel = {
        let label = UILabel()
        label.textAlignment = .center
        label.numberOfLines = 0
        label.themeTextColor = .textSecondary
        label.font = .systemFont(ofSize: Values.smallFontSize, weight: .regular)
        return label
    }()
    
    private lazy var primaryButton: UIButton = {
        let button = UIButton(type: .custom)
        button.setThemeTitleColor(.sessionButton_text, for: .normal)
        button.setThemeTitleColor(.sessionButton_highlight, for: .highlighted)
        
        button.titleLabel?.numberOfLines = 3
        button.titleLabel?.textAlignment = .center
        
        button.addTarget(self, action: #selector(primaryEvent), for: .touchUpInside)
        
        return button
    }()
    
    private lazy var secondaryButton: UIButton = {
        let button = UIButton(type: .custom)
        button.setThemeTitleColor(.textPrimary, for: .normal)
        button.setThemeTitleColor(.textSecondary, for: .highlighted)
        
        button.titleLabel?.numberOfLines = 3
        button.titleLabel?.textAlignment = .center
        
        button.addTarget(self, action: #selector(secondaryEvent), for: .touchUpInside)
 
        return button
    }()
    
    private lazy var buttonStack: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [
            primaryButton,
            secondaryButton
        ])
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.alignment = .fill
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = .init(
            top: Values.mediumSpacing,
            left: 0,
            bottom: Values.mediumSpacing,
            right: 0
        )
        
        return stack
    }()
    
    private lazy var contentStack: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [
            titleLabel,
            messageLabel,
            buttonStack
        ])
        stack.axis = .vertical
        stack.distribution = .fill
        stack.spacing = 6
        return stack
    }()
    
    private var prompt: AppReviewPromptState = .none
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        
        setupHierarchy()
        setupLayout()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func updatePrompt(_ prompt: AppReviewPromptState) {
        self.prompt = prompt
        
        isHidden = prompt == .none
        
        titleLabel.text = prompt.promptContent.title
        messageLabel.text = prompt.promptContent.message
        
        primaryButton.setTitle(prompt.promptContent.primaryButtonTitle, for: .normal)
        secondaryButton.setTitle(prompt.promptContent.secondaryButtonTitle, for: .normal)
        
        delegate?.didChangePromptState(prompt)
    }
    
    @objc
    func close() {
        let prevState = prompt
        
        updatePrompt(.none)
        
        switch prevState {
        case .rateSession: delegate?.didCloseBeforeReview()
        default : break
        }
    }
    
    @objc
    func primaryEvent() {
        switch prompt {
        case .enjoyingSession:
            updatePrompt(.rateSession)
        default: delegate?.willHandlePromptState(prompt, isPrimary: true)
        }
    }
    
    @objc
    func secondaryEvent() {
        switch prompt {
        case .enjoyingSession: updatePrompt(.feedback)
        default: delegate?.willHandlePromptState(prompt, isPrimary: false)
        }
    }
}

private extension AppReviewPromptDialog {
    func setupHierarchy() {
        addSubview(closeButton)
        addSubview(contentStack)
    }
    
    func setupLayout() {
        closeButton.pin(.top, to: .top, of: self, withInset: Values.smallSpacing)
        closeButton.pin(.right, to: .right, of: self, withInset: -Values.smallSpacing)
        
        contentStack.pin(.top, to: .bottom, of: closeButton)
        contentStack.pin(.left, to: .left, of: self, withInset: Values.mediumSmallSpacing)
        contentStack.pin(.right, to: .right, of: self, withInset: -Values.mediumSmallSpacing)
        contentStack.pin(.bottom, to: .bottom, of: self, withInset: -Values.mediumSmallSpacing)
    }
}
