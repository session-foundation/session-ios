// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit

class AppReviewPromptDialog: UIView {
    var onCloseTapped: (() -> Void)?
    var onPrimaryTapped: ((AppReviewPromptState) -> Void)?
    var onSecondaryTapped: ((AppReviewPromptState) -> Void)?
    
    private static let closeSize: CGFloat = 24

    private lazy var closeButton: UIButton = UIButton(primaryAction: UIAction { [weak self] _ in self?.close() })
        .withConfiguration(
            UIButton.Configuration
                .plain()
                .withImage(UIImage(named: "X")?.withRenderingMode(.alwaysTemplate))
                .withContentInsets(NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))
        )
        .withConfigurationUpdateHandler { button in
            switch button.state {
                case .highlighted: button.imageView?.tintAdjustmentMode = .dimmed
                default: button.imageView?.tintAdjustmentMode = .normal
            }
        }
        .withImageViewContentMode(.scaleAspectFit)
        .withThemeTintColor(.textPrimary)
        .withAccessibility(
            identifier: "Close button"
        )
        .with(.width, of: AppReviewPromptDialog.closeSize)
        .with(.height, of: AppReviewPromptDialog.closeSize)
    
    private lazy var titleLabel: UILabel = {
        let result = UILabel()
        result.textAlignment = .center
        result.numberOfLines = 0
        result.themeTextColor = .alert_text
        result.font = .boldSystemFont(ofSize: Values.mediumFontSize)
        
        return result
    }()
    
    private lazy var messageLabel: UILabel = {
        let result = UILabel()
        result.textAlignment = .center
        result.numberOfLines = 0
        result.themeTextColor = .alert_text
        result.font = ConfirmationModal.explanationFont
        
        return result
    }()
    
    private lazy var primaryButton: UIButton = {
        let result = UIButton(type: .custom)
        result.setThemeTitleColor(.sessionButton_text, for: .normal)
        result.setThemeTitleColor(.highlighted(.sessionButton_text, alwaysDarken: false), for: .highlighted)
        result.titleLabel?.font = .boldSystemFont(ofSize: Values.mediumFontSize)
        result.titleLabel?.numberOfLines = 0
        result.titleLabel?.textAlignment = .center
        result.addTarget(self, action: #selector(primaryEvent), for: .touchUpInside)
        
        return result
    }()
    
    private lazy var secondaryButton: UIButton = {
        let result = UIButton(type: .custom)
        result.setThemeTitleColor(.textPrimary, for: .normal)
        result.setThemeTitleColor(.highlighted(.textPrimary, alwaysDarken: false), for: .highlighted)
        result.titleLabel?.font = .boldSystemFont(ofSize: Values.mediumFontSize)
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
        result.layoutMargins = UIEdgeInsets(
            top: Values.largeSpacing,
            left: Values.veryLargeSpacing,
            bottom: Values.verySmallSpacing,
            right: Values.veryLargeSpacing
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
        titleLabel.accessibilityIdentifier = "Modal heading"
        titleLabel.accessibilityLabel = titleLabel.text
        
        messageLabel.text = prompt?.promptContent.message
        messageLabel.accessibilityIdentifier = "Modal description"
        messageLabel.accessibilityLabel = messageLabel.text
        
        primaryButton.isHidden = prompt?.promptContent.primaryButtonTitle == nil
        primaryButton.setTitle(prompt?.promptContent.primaryButtonTitle, for: .normal)
        primaryButton.setThemeTitleColor(prompt?.promptContent.primaryButtonColor, for: .normal)
        primaryButton.setThemeTitleColor(
            (prompt?.promptContent.primaryButtonColor).map { .highlighted($0, alwaysDarken: false) },
            for: .highlighted
        )
        primaryButton.accessibilityIdentifier = prompt?.promptContent.primaryButtonAccessibilityIdentifier
        
        secondaryButton.isHidden = prompt?.promptContent.secondaryButtonTitle == nil
        secondaryButton.setTitle(prompt?.promptContent.secondaryButtonTitle, for: .normal)
        secondaryButton.setThemeTitleColor(prompt?.promptContent.secondaryButtonColor, for: .normal)
        secondaryButton.setThemeTitleColor(
            (prompt?.promptContent.secondaryButtonColor).map { .highlighted($0, alwaysDarken: false) },
            for: .highlighted
        )
        secondaryButton.accessibilityIdentifier = prompt?.promptContent.secondaryButtonAccessibilityIdentifier
        
        let isButtonsHidden = primaryButton.isHidden && secondaryButton.isHidden
        
        buttonStack.layoutMargins = .init(
            top: isButtonsHidden ? 0: Values.mediumSpacing,
            left: 0,
            bottom: Values.mediumSpacing,
            right: 0
        )
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
        addSubview(contentStack)
        addSubview(closeButton)
    }
    
    func setupLayout() {
        closeButton.pin(.top, to: .top, of: self, withInset: Values.smallSpacing)
        closeButton.pin(.right, to: .right, of: self, withInset: -Values.smallSpacing)
        
        contentStack.pin(to: self)
    }
}
