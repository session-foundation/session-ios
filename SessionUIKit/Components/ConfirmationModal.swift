// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUtilitiesKit

// FIXME: Refactor as part of the Groups Rebuild
public class ConfirmationModal: Modal {
    private static let imageSize: CGFloat = 80
    private static let closeSize: CGFloat = 24
    
    private var internalOnConfirm: ((ConfirmationModal) -> ())? = nil
    private var internalOnCancel: ((ConfirmationModal) -> ())? = nil
    private var internalOnBodyTap: (() -> ())? = nil
    
    // MARK: - Components
    
    private lazy var titleLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = .boldSystemFont(ofSize: Values.mediumFontSize)
        result.themeTextColor = .alert_text
        result.textAlignment = .center
        result.lineBreakMode = .byWordWrapping
        result.numberOfLines = 0
        
        return result
    }()
    
    private lazy var explanationLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = .systemFont(ofSize: Values.smallFontSize)
        result.themeTextColor = .alert_text
        result.textAlignment = .center
        result.lineBreakMode = .byWordWrapping
        result.numberOfLines = 0
        result.isHidden = true
        
        return result
    }()
    
    private lazy var imageViewContainer: UIView = {
        let result: UIView = UIView()
        result.isHidden = true
        
        return result
    }()
    
    private lazy var imageView: UIImageView = {
        let result: UIImageView = UIImageView()
        result.clipsToBounds = true
        result.contentMode = .scaleAspectFill
        result.set(.width, to: ConfirmationModal.imageSize)
        result.set(.height, to: ConfirmationModal.imageSize)
        
        return result
    }()
    
    private lazy var confirmButton: UIButton = {
        let result: UIButton = Modal.createButton(
            title: "",
            titleColor: .danger
        )
        result.addTarget(self, action: #selector(confirmationPressed), for: .touchUpInside)
        
        return result
    }()
    
    private lazy var buttonStackView: UIStackView = {
        let result = UIStackView(arrangedSubviews: [ confirmButton, cancelButton ])
        result.axis = .horizontal
        result.distribution = .fillEqually
        
        return result
    }()
    
    private lazy var contentStackView: UIStackView = {
        let result = UIStackView(arrangedSubviews: [ titleLabel, explanationLabel, imageViewContainer ])
        result.axis = .vertical
        result.spacing = Values.smallSpacing
        result.isLayoutMarginsRelativeArrangement = true
        result.layoutMargins = UIEdgeInsets(
            top: Values.largeSpacing,
            left: Values.largeSpacing,
            bottom: Values.verySmallSpacing,
            right: Values.largeSpacing
        )
        
        let gestureRecogniser: UITapGestureRecognizer = UITapGestureRecognizer(
            target: self,
            action: #selector(bodyTapped)
        )
        result.addGestureRecognizer(gestureRecogniser)
        
        return result
    }()
    
    private lazy var mainStackView: UIStackView = {
        let result = UIStackView(arrangedSubviews: [ contentStackView, buttonStackView ])
        result.axis = .vertical
        
        return result
    }()
    
    private lazy var closeButton: UIButton = {
        let result: UIButton = UIButton()
        result.setImage(
            UIImage(named: "X")?
                .withRenderingMode(.alwaysTemplate),
            for: .normal
        )
        result.imageView?.contentMode = .scaleAspectFit
        result.themeTintColor = .textPrimary
        result.contentEdgeInsets = UIEdgeInsets(
            top: 6,
            left: 6,
            bottom: 6,
            right: 6
        )
        result.set(.width, to: ConfirmationModal.closeSize)
        result.set(.height, to: ConfirmationModal.closeSize)
        result.addTarget(self, action: #selector(close), for: .touchUpInside)
        result.isHidden = true
        
        return result
    }()
    
    // MARK: - Lifecycle
    
    public init(targetView: UIView? = nil, info: Info) {
        super.init(targetView: targetView, dismissType: info.dismissType, afterClosed: info.afterClosed)
        
        self.modalPresentationStyle = .overFullScreen
        self.modalTransitionStyle = .crossDissolve
        self.updateContent(with: info)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override func populateContentView() {
        contentView.addSubview(mainStackView)
        contentView.addSubview(closeButton)
        
        imageViewContainer.addSubview(imageView)
        imageView.center(.horizontal, in: imageViewContainer)
        imageView.pin(.top, to: .top, of: imageViewContainer, withInset: 15)
        imageView.pin(.bottom, to: .bottom, of: imageViewContainer, withInset: -15)
        
        mainStackView.pin(to: contentView)
        closeButton.pin(.top, to: .top, of: contentView, withInset: 8)
        closeButton.pin(.right, to: .right, of: contentView, withInset: -8)
    }
    
    // MARK: - Content
    
    public func updateContent(with info: Info) {
        internalOnBodyTap = nil
        internalOnConfirm = { modal in
            if info.dismissOnConfirm {
                modal.close()
            }
            
            info.onConfirm?(modal)
        }
        internalOnCancel = { modal in
            guard info.onCancel != nil else { return modal.close() }
            
            info.onCancel?(modal)
        }
        
        // Set the content based on the provided info
        titleLabel.text = info.title
        
        switch info.body {
            case .none:
                mainStackView.spacing = Values.smallSpacing
                
            case .text(let text):
                mainStackView.spacing = Values.smallSpacing
                explanationLabel.text = text
                explanationLabel.isHidden = false
                
            case .attributedText(let attributedText):
                mainStackView.spacing = Values.smallSpacing
                explanationLabel.attributedText = attributedText
                explanationLabel.isHidden = false
                
            case .image(let placeholder, let value, let style, let onClick):
                mainStackView.spacing = 0
                imageView.image = (value ?? placeholder)
                imageView.layer.cornerRadius = (style == .circular ?
                    (ConfirmationModal.imageSize / 2) :
                    0
                )
                imageViewContainer.isHidden = false
                internalOnBodyTap = onClick
        }
        
        confirmButton.accessibilityLabel = info.confirmAccessibility?.label
        confirmButton.accessibilityIdentifier = info.confirmAccessibility?.identifier
        confirmButton.isAccessibilityElement = true
        confirmButton.setTitle(info.confirmTitle, for: .normal)
        confirmButton.setThemeTitleColor(info.confirmStyle, for: .normal)
        confirmButton.setThemeTitleColor(.disabled, for: .disabled)
        confirmButton.isHidden = (info.confirmTitle == nil)
        confirmButton.isEnabled = info.confirmEnabled
        cancelButton.accessibilityLabel = info.cancelAccessibility?.label
        cancelButton.accessibilityIdentifier = info.cancelAccessibility?.identifier
        cancelButton.isAccessibilityElement = true
        cancelButton.setTitle(info.cancelTitle, for: .normal)
        cancelButton.setThemeTitleColor(info.cancelStyle, for: .normal)
        cancelButton.setThemeTitleColor(.disabled, for: .disabled)
        cancelButton.isEnabled = info.cancelEnabled
        closeButton.isHidden = !info.hasCloseButton
        
        contentView.accessibilityLabel = info.accessibility?.label
        contentView.accessibilityIdentifier = info.accessibility?.identifier
    }
    
    // MARK: - Interaction
    
    @objc private func bodyTapped() {
        internalOnBodyTap?()
    }
    
    @objc private func confirmationPressed() {
        internalOnConfirm?(self)
    }
    
    override public func cancel() {
        internalOnCancel?(self)
    }
}

// MARK: - Types

public extension ConfirmationModal {
    struct Info: Equatable, Hashable {
        let title: String
        let body: Body
        let accessibility: Accessibility?
        public let showCondition: ShowCondition
        let confirmTitle: String?
        let confirmAccessibility: Accessibility?
        let confirmStyle: ThemeValue
        let confirmEnabled: Bool
        let cancelTitle: String
        let cancelAccessibility: Accessibility?
        let cancelStyle: ThemeValue
        let cancelEnabled: Bool
        let hasCloseButton: Bool
        let dismissOnConfirm: Bool
        let dismissType: Modal.DismissType
        let onConfirm: ((ConfirmationModal) -> ())?
        let onCancel: ((ConfirmationModal) -> ())?
        let afterClosed: (() -> ())?
        
        // MARK: - Initialization
        
        public init(
            title: String,
            body: Body = .none,
            accessibility: Accessibility? = nil,
            showCondition: ShowCondition = .none,
            confirmTitle: String? = nil,
            confirmAccessibility: Accessibility? = nil,
            confirmStyle: ThemeValue = .alert_text,
            confirmEnabled: Bool = true,
            cancelTitle: String = "TXT_CANCEL_TITLE".localized(),
            cancelAccessibility: Accessibility? = Accessibility(
                identifier: "Cancel"
            ),
            cancelStyle: ThemeValue = .danger,
            cancelEnabled: Bool = true,
            hasCloseButton: Bool = false,
            dismissOnConfirm: Bool = true,
            dismissType: Modal.DismissType = .recursive,
            onConfirm: ((ConfirmationModal) -> ())? = nil,
            onCancel: ((ConfirmationModal) -> ())? = nil,
            afterClosed: (() -> ())? = nil
        ) {
            self.title = title
            self.body = body
            self.accessibility = accessibility
            self.showCondition = showCondition
            self.confirmTitle = confirmTitle
            self.confirmAccessibility = confirmAccessibility
            self.confirmStyle = confirmStyle
            self.confirmEnabled = confirmEnabled
            self.cancelTitle = cancelTitle
            self.cancelAccessibility = cancelAccessibility
            self.cancelStyle = cancelStyle
            self.cancelEnabled = cancelEnabled
            self.hasCloseButton = hasCloseButton
            self.dismissOnConfirm = dismissOnConfirm
            self.dismissType = dismissType
            self.onConfirm = onConfirm
            self.onCancel = onCancel
            self.afterClosed = afterClosed
        }
        
        // MARK: - Mutation
        
        public func with(
            body: Body? = nil,
            confirmEnabled: Bool? = nil,
            cancelEnabled: Bool? = nil,
            onConfirm: ((ConfirmationModal) -> ())? = nil,
            onCancel: ((ConfirmationModal) -> ())? = nil,
            afterClosed: (() -> ())? = nil
        ) -> Info {
            return Info(
                title: self.title,
                body: (body ?? self.body),
                accessibility: self.accessibility,
                showCondition: self.showCondition,
                confirmTitle: self.confirmTitle,
                confirmAccessibility: self.confirmAccessibility,
                confirmStyle: self.confirmStyle,
                confirmEnabled: (confirmEnabled ?? self.confirmEnabled),
                cancelTitle: self.cancelTitle,
                cancelAccessibility: self.cancelAccessibility,
                cancelStyle: self.cancelStyle,
                cancelEnabled: (cancelEnabled ?? self.cancelEnabled),
                hasCloseButton: self.hasCloseButton,
                dismissOnConfirm: self.dismissOnConfirm,
                dismissType: self.dismissType,
                onConfirm: (onConfirm ?? self.onConfirm),
                onCancel: (onCancel ?? self.onCancel),
                afterClosed: (afterClosed ?? self.afterClosed)
            )
        }
        
        // MARK: - Confirmance
        
        public static func == (lhs: ConfirmationModal.Info, rhs: ConfirmationModal.Info) -> Bool {
            return (
                lhs.title == rhs.title &&
                lhs.body == rhs.body &&
                lhs.accessibility == rhs.accessibility &&
                lhs.showCondition == rhs.showCondition &&
                lhs.confirmTitle == rhs.confirmTitle &&
                lhs.confirmAccessibility == rhs.confirmAccessibility &&
                lhs.confirmStyle == rhs.confirmStyle &&
                lhs.confirmEnabled == rhs.confirmEnabled &&
                lhs.cancelTitle == rhs.cancelTitle &&
                lhs.cancelAccessibility == rhs.cancelAccessibility &&
                lhs.cancelStyle == rhs.cancelStyle &&
                lhs.cancelEnabled == rhs.cancelEnabled &&
                lhs.hasCloseButton == rhs.hasCloseButton &&
                lhs.dismissOnConfirm == rhs.dismissOnConfirm &&
                lhs.dismissType == rhs.dismissType
            )
        }
        
        public func hash(into hasher: inout Hasher) {
            title.hash(into: &hasher)
            body.hash(into: &hasher)
            accessibility.hash(into: &hasher)
            showCondition.hash(into: &hasher)
            confirmTitle.hash(into: &hasher)
            confirmAccessibility.hash(into: &hasher)
            confirmStyle.hash(into: &hasher)
            confirmEnabled.hash(into: &hasher)
            cancelTitle.hash(into: &hasher)
            cancelAccessibility.hash(into: &hasher)
            cancelStyle.hash(into: &hasher)
            cancelEnabled.hash(into: &hasher)
            hasCloseButton.hash(into: &hasher)
            dismissOnConfirm.hash(into: &hasher)
            dismissType.hash(into: &hasher)
        }
    }
}

public extension ConfirmationModal.Info {
    // MARK: - ShowCondition
    
    enum ShowCondition {
        case none
        case enabled
        case disabled
        
        public func shouldShow(for value: Bool) -> Bool {
            switch self {
                case .none: return true
                case .enabled: return (value == true)
                case .disabled: return (value == false)
            }
        }
    }
    
    // MARK: - Body
    
    enum Body: Equatable, Hashable {
        public enum ImageStyle: Equatable, Hashable {
            case inherit
            case circular
        }
        
        case none
        case text(String)
        case attributedText(NSAttributedString)
        // FIXME: Implement these
        // case input(placeholder: String, value: String?)
        // case radio(explanation: NSAttributedString?, options: [(title: String, selected: Bool)])
        case image(
            placeholder: UIImage?,
            value: UIImage?,
            style: ImageStyle,
            onClick: (() -> ())
        )
        
        public static func == (lhs: ConfirmationModal.Info.Body, rhs: ConfirmationModal.Info.Body) -> Bool {
            switch (lhs, rhs) {
                case (.none, .none): return true
                case (.text(let lhsText), .text(let rhsText)): return (lhsText == rhsText)
                case (.attributedText(let lhsText), .attributedText(let rhsText)): return (lhsText == rhsText)
                
                // FIXME: Implement these
                //case (.input(let lhsPlaceholder, let lhsValue), .input(let rhsPlaceholder, let rhsValue)):
                //    return (
                //        lhsPlaceholder == rhsPlaceholder &&
                //        lhsValue == rhsValue &&
                //    )
                
                // FIXME: Implement these
                //case (.radio(let lhsExplanation, let lhsOptions), .radio(let rhsExplanation, let rhsOptions)):
                //    return (
                //        lhsExplanation == rhsExplanation &&
                //        lhsOptions.map { "\($0.0)-\($0.1)" } == rhsValue.map { "\($0.0)-\($0.1)" }
                //    )
                    
                case (.image(let lhsPlaceholder, let lhsValue, let lhsStyle, _), .image(let rhsPlaceholder, let rhsValue, let rhsStyle, _)):
                    return (
                        lhsPlaceholder == rhsPlaceholder &&
                        lhsValue == rhsValue &&
                        lhsStyle == rhsStyle
                    )
                    
                default: return false
            }
        }
        
        public func hash(into hasher: inout Hasher) {
            switch self {
                case .none: break
                case .text(let text): text.hash(into: &hasher)
                case .attributedText(let text): text.hash(into: &hasher)
                
                case .image(let placeholder, let value, let style, _):
                    placeholder.hash(into: &hasher)
                    value.hash(into: &hasher)
                    style.hash(into: &hasher)
            }
        }
    }
}
