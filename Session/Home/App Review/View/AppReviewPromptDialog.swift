// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit

class AppReviewPromptDialog: UIView {
    var onCloseTapped: (() -> Void)?
    var onPrimaryTapped: ((AppReviewPromptState) -> Void)?
    var onSecondaryTapped: ((AppReviewPromptState) -> Void)?
    
    private lazy var closeButton: UIButton = {
        let result = UIButton(type: .custom)
        result.setImage(
            UIImage(named: "X")?
                .withRenderingMode(.alwaysTemplate),
            for: .normal
        )
        result.themeTintColor = .textPrimary
        result.addTarget(self, action: #selector(close), for: UIControl.Event.touchUpInside)
        result.set(.width, to: Values.largeSpacing)
        result.set(.height, to: Values.largeSpacing)
        
       return result
    }()
    
    private lazy var titleLabel: UILabel = {
        let result = UILabel()
        result.textAlignment = .center
        result.numberOfLines = 0
        result.themeTextColor = .textPrimary
        result.font = .systemFont(ofSize: 18, weight: .bold)
        
        return result
    }()
    
    private lazy var messageLabel: UILabel = {
        let result = UILabel()
        result.textAlignment = .center
        result.numberOfLines = 0
        result.themeTextColor = .textSecondary
        result.font = .systemFont(ofSize: 16, weight: .regular)
        
        return result
    }()
    
    private lazy var primaryButton: UIButton = {
        let result = UIButton(type: .custom)
        result.setThemeTitleColor(.sessionButton_text, for: .normal)
        result.setThemeTitleColor(.sessionButton_highlight, for: .highlighted)
        result.titleLabel?.font = .systemFont(ofSize: 16, weight: .bold)
        result.titleLabel?.numberOfLines = 0
        result.titleLabel?.textAlignment = .center
        result.addTarget(self, action: #selector(primaryEvent), for: .touchUpInside)
        
        return result
    }()
    
    private lazy var secondaryButton: UIButton = {
        let result = UIButton(type: .custom)
        result.setThemeTitleColor(.textPrimary, for: .normal)
        result.setThemeTitleColor(.textSecondary, for: .highlighted)
        result.titleLabel?.font = .systemFont(ofSize: 16, weight: .bold)
        result.titleLabel?.numberOfLines = 0
        result.titleLabel?.textAlignment = .center
        result.addTarget(self, action: #selector(secondaryEvent), for: .touchUpInside)
 
        return result
    }()
    
    private lazy var buttonStack: UIStackView = {
        let result = UIStackView(arrangedSubviews: [
            primaryButton,
            secondaryButton
        ])
        result.axis = .horizontal
        result.distribution = .fillEqually
        result.alignment = .fill
        result.isLayoutMarginsRelativeArrangement = true
        result.layoutMargins = .init(
            top: Values.mediumSpacing,
            left: 0,
            bottom: Values.mediumSpacing,
            right: 0
        )
        
        return result
    }()
    
    private lazy var contentStack: UIStackView = {
        let result = UIStackView(arrangedSubviews: [
            titleLabel,
            messageLabel,
            buttonStack
        ])
        result.axis = .vertical
        result.distribution = .fill
        result.spacing = 8
        result.isLayoutMarginsRelativeArrangement = true
        result.layoutMargins = .init(
            top: 0,
            left: Values.largeSpacing,
            bottom: 0,
            right: Values.largeSpacing
        )
        
        return result
    }()
    
    private var prompt: AppReviewPromptState?
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        
        setupHierarchy()
        setupLayout()
        
        setReviewPrompt(nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func setReviewPrompt(_ prompt: AppReviewPromptState?) {
        self.prompt = prompt
        
        isHidden = prompt == nil
        
        titleLabel.text = prompt?.promptContent.title
        messageLabel.text = prompt?.promptContent.message
        
        primaryButton.setTitle(prompt?.promptContent.primaryButtonTitle, for: .normal)
        secondaryButton.setTitle(prompt?.promptContent.secondaryButtonTitle, for: .normal)
    }
    
    @objc
    func close() {
        onCloseTapped?()
    }
    
    @objc
    func primaryEvent() {
        let current = prompt ?? .enjoyingSession
        onPrimaryTapped?(current)
    }
    
    @objc
    func secondaryEvent() {
        let current = prompt ?? .enjoyingSession
        onSecondaryTapped?(current)
    }
}

private extension AppReviewPromptDialog {
    func setupHierarchy() {
        addSubview(closeButton)
        addSubview(contentStack)
    }
    
    func setupLayout() {
        closeButton.pin(.top, to: .top, of: self, withInset: Values.mediumSmallSpacing)
        closeButton.pin(.right, to: .right, of: self, withInset: -Values.mediumSmallSpacing)
        
        contentStack.pin(.top, to: .bottom, of: closeButton)
        contentStack.pin(.left, to: .left, of: self, withInset: Values.mediumSmallSpacing)
        contentStack.pin(.right, to: .right, of: self, withInset: -Values.mediumSmallSpacing)
        contentStack.pin(.bottom, to: .bottom, of: self, withInset: -Values.mediumSmallSpacing)
    }
}
