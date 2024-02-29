// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit

final class InfoBanner: UIView {
    public struct Info: Equatable, Hashable {
        let message: String
        let backgroundColor: ThemeValue
        let messageFont: UIFont
        let messageTintColor: ThemeValue
        let messageLabelAccessibilityLabel: String?
        let height: CGFloat
        
        func with(
            message: String? = nil,
            backgroundColor: ThemeValue? = nil,
            messageFont: UIFont? = nil,
            messageTintColor: ThemeValue? = nil,
            messageLabelAccessibilityLabel: String? = nil,
            height: CGFloat? = nil
        ) -> Info {
            return Info(
                message: message ?? self.message,
                backgroundColor: backgroundColor ?? self.backgroundColor,
                messageFont: messageFont ?? self.messageFont,
                messageTintColor: messageTintColor ?? self.messageTintColor,
                messageLabelAccessibilityLabel: messageLabelAccessibilityLabel ?? self.messageLabelAccessibilityLabel,
                height: height ?? self.height
            )
        }
    }
    
    private lazy var label: UILabel = {
        let result: UILabel = UILabel()
        result.textAlignment = .center
        result.lineBreakMode = .byWordWrapping
        result.numberOfLines = 0
        result.isAccessibilityElement = true
        
        return result
    }()
    
    private lazy var closeButton: UIButton = {
        let result: UIButton = UIButton()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.setImage(
            UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold))?
                .withRenderingMode(.alwaysTemplate),
            for: .normal
        )
        result.contentMode = .center
        result.addTarget(self, action: #selector(dismissBanner), for: .touchUpInside)
        
        return result
    }()
    
    public var info: Info?
    public var dismiss: (() -> Void)?
    
    // MARK: - Initialization
    
    init(info: Info, dismiss: (() -> Void)? = nil) {
        super.init(frame: CGRect.zero)
        
        addSubview(label)
        
        label.pin(.top, to: .top, of: self)
        label.pin(.bottom, to: .bottom, of: self)
        label.pin(.leading, to: .leading, of: self, withInset: Values.veryLargeSpacing)
        label.pin(.trailing, to: .trailing, of: self, withInset: -Values.veryLargeSpacing)
        
        addSubview(closeButton)
        
        let buttonSize: CGFloat = (12 + (Values.smallSpacing * 2))
        closeButton.center(.vertical, in: self)
        closeButton.pin(.trailing, to: .trailing, of: self, withInset: -Values.smallSpacing)
        closeButton.set(.width, to: buttonSize)
        closeButton.set(.height, to: buttonSize)
        
        self.set(.height, to: info.height)
        self.update(info, dismiss: dismiss)
    }
    
    override init(frame: CGRect) {
        preconditionFailure("Use init(message:) instead.")
    }
    
    required init?(coder: NSCoder) {
        preconditionFailure("Use init(coder:) instead.")
    }
    
    // MARK: Update
    
    private func update(_ info: InfoBanner.Info, dismiss: (() -> Void)?) {
        self.info = info
        self.dismiss = dismiss
        
        themeBackgroundColor = info.backgroundColor
        
        label.font = info.messageFont
        label.text = info.message
        label.themeTextColor = info.messageTintColor
        label.accessibilityLabel = info.messageLabelAccessibilityLabel
        
        closeButton.themeTintColor = info.messageTintColor
        closeButton.isHidden = (dismiss == nil)
    }
    
    public func update(
        message: String? = nil,
        backgroundColor: ThemeValue? = nil,
        messageFont: UIFont? = nil,
        messageTintColor: ThemeValue? = nil,
        messageLabelAccessibilityLabel: String? = nil,
        height: CGFloat? = nil,
        dismiss: (() -> Void)? = nil
    ) {
        if let updatedInfo = self.info?.with(
            message: message,
            backgroundColor: backgroundColor,
            messageFont: messageFont,
            messageTintColor: messageTintColor,
            messageLabelAccessibilityLabel: messageLabelAccessibilityLabel,
            height: height
        ) {
            self.update(updatedInfo, dismiss: dismiss)
        }
    }
    
    // MARK: - Actions
    
    @objc private func dismissBanner() {
        self.dismiss?()
    }
}
