// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

final class ConversationTitleView: UIView {
    private static let leftInset: CGFloat = 8
    private static let leftInsetWithCallButton: CGFloat = 54
    
    private var oldSize: CGSize = .zero
    
    override var intrinsicContentSize: CGSize {
        return UIView.layoutFittingExpandedSize
    }
    
    private lazy var labelCarouselViewWidth = labelCarouselView.set(.width, to: 185)
    
    public var currentLabelType: SessionLabelCarouselView.LabelType {
        return self.labelCarouselView.currentLabelType
    }

    // MARK: - UI Components
    
    private lazy var stackViewLeadingConstraint: NSLayoutConstraint = stackView.pin(.leading, to: .leading, of: self)
    private lazy var stackViewTrailingConstraint: NSLayoutConstraint = stackView.pin(.trailing, to: .trailing, of: self)
    
    private lazy var titleLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = .boldSystemFont(ofSize: Values.mediumFontSize)
        result.themeTextColor = .textPrimary
        result.lineBreakMode = .byTruncatingTail
        
        return result
    }()
    
    private lazy var labelCarouselView: SessionLabelCarouselView = {
        let result = SessionLabelCarouselView()
        return result
    }()
    
    private lazy var stackView: UIStackView = {
        let result = UIStackView(arrangedSubviews: [ titleLabel, labelCarouselView ])
        result.axis = .vertical
        result.alignment = .center
        
        return result
    }()

    // MARK: - Initialization
    
    init() {
        super.init(frame: .zero)
        
        addSubview(stackView)
        
        stackView.pin(.top, to: .top, of: self)
        stackViewLeadingConstraint.isActive = true
        stackViewTrailingConstraint.isActive = true
        stackView.pin(.bottom, to: .bottom, of: self)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    required init?(coder: NSCoder) {
        preconditionFailure("Use init() instead.")
    }

    // MARK: - Content
    
    public func initialSetup(with threadVariant: SessionThread.Variant) {
        self.update(
            with: " ",
            isNoteToSelf: false,
            threadVariant: threadVariant,
            mutedUntilTimestamp: nil,
            onlyNotifyForMentions: false,
            userCount: (threadVariant != .contact ? 0 : nil),
            disappearingMessagesConfig: nil
        )
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        
        // There is an annoying issue where pushing seems to update the width of this
        // view resulting in the content shifting to the right during
        guard self.oldSize != .zero, self.oldSize != bounds.size else {
            self.oldSize = bounds.size
            return
        }
        
        let diff: CGFloat = (bounds.size.width - oldSize.width)
        self.stackViewTrailingConstraint.constant = -max(0, diff)
        self.oldSize = bounds.size
    }
    
    public func update(
        with name: String,
        isNoteToSelf: Bool,
        threadVariant: SessionThread.Variant,
        mutedUntilTimestamp: TimeInterval?,
        onlyNotifyForMentions: Bool,
        userCount: Int?,
        disappearingMessagesConfig: DisappearingMessagesConfiguration?
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.update(
                    with: name,
                    isNoteToSelf: isNoteToSelf,
                    threadVariant: threadVariant,
                    mutedUntilTimestamp: mutedUntilTimestamp,
                    onlyNotifyForMentions: onlyNotifyForMentions,
                    userCount: userCount,
                    disappearingMessagesConfig: disappearingMessagesConfig
                )
            }
            return
        }
        
        let shouldHaveSubtitle: Bool = (
            Date().timeIntervalSince1970 <= (mutedUntilTimestamp ?? 0) ||
            onlyNotifyForMentions ||
            userCount != nil ||
            disappearingMessagesConfig?.isEnabled == true
        )
        
        self.titleLabel.text = name
        self.titleLabel.font = .boldSystemFont(
            ofSize: (shouldHaveSubtitle ?
                Values.largeFontSize :
                Values.veryLargeFontSize
            )
        )
        
        ThemeManager.onThemeChange(observer: self.labelCarouselView) { [weak self] theme, _ in
            guard let textPrimary: UIColor = theme.color(for: .textPrimary) else { return }
            
            var labelStrings: [NSAttributedString] = []
            var labelTypes: [SessionLabelCarouselView.LabelType] = []
            
            if Date().timeIntervalSince1970 <= (mutedUntilTimestamp ?? 0) {
                let notificationSettingsLabelString = NSAttributedString(
                    string: "\u{e067}  ",
                    attributes: [
                        .font: UIFont.ows_elegantIconsFont(10),
                        .foregroundColor: textPrimary
                    ]
                )
                .appending(string: "Muted")
                
                labelStrings.append(notificationSettingsLabelString)
                labelTypes.append(.notificationSettings)
            } else if onlyNotifyForMentions{
                let imageAttachment = NSTextAttachment()
                imageAttachment.image = UIImage(named: "NotifyMentions.png")?.withTint(textPrimary)
                imageAttachment.bounds = CGRect(
                    x: 0,
                    y: -2,
                    width: Values.miniFontSize,
                    height: Values.miniFontSize
                )
                
                let notificationSettingsLabelString = NSAttributedString(attachment: imageAttachment)
                    .appending(string: "  ")
                    .appending(string: "view_conversation_title_notify_for_mentions_only".localized())
                
                labelStrings.append(notificationSettingsLabelString)
                labelTypes.append(.notificationSettings)
            }
            
            if let userCount: Int = userCount {
                let userCountLabelString: NSAttributedString = {
                    switch threadVariant {
                        case .contact: return NSAttributedString(string: "") // Should not happen
                            
                        case .closedGroup:
                            return NSAttributedString(
                                string: "\(userCount) member\(userCount == 1 ? "" : "s")"
                            )
                            
                        case .openGroup:
                            return NSAttributedString(
                                string: "\(userCount) active member\(userCount == 1 ? "" : "s")"
                            )
                    }
                }()
                
                labelStrings.append(userCountLabelString)
                labelTypes.append(.userCount)
            }
            
            if let config = disappearingMessagesConfig, config.isEnabled == true {
                let imageAttachment = NSTextAttachment()
                imageAttachment.image = UIImage(systemName: "timer")?.withTint(textPrimary)
                imageAttachment.bounds = CGRect(
                    x: 0,
                    y: -2,
                    width: Values.miniFontSize,
                    height: Values.miniFontSize
                )
                
                let disappearingMessageSettingLabelString = NSAttributedString(attachment: imageAttachment)
                    .appending(string: " ")
                    .appending(string: config.type == .disappearAfterRead ? "DISAPPERING_MESSAGES_TYPE_AFTER_READ_TITLE".localized() : "DISAPPERING_MESSAGES_TYPE_AFTER_SEND_TITLE".localized())
                    .appending(string: " - ")
                    .appending(string: floor(config.durationSeconds).formatted(format: .short))
                
                labelStrings.append(disappearingMessageSettingLabelString)
                labelTypes.append(.disappearingMessageSetting)
            }
            
            self?.labelCarouselView.update(
                with: labelStrings,
                labelTypes: labelTypes,
                labelSize: CGSize(
                    width: self?.labelCarouselViewWidth.constant ?? 0,
                    height: 14
                ),
                shouldAutoScroll: false
            )
            
            self?.labelCarouselView.isHidden = (labelStrings.count == 0)
        }
        
        // Contact threads also have the call button to compensate for
        let shouldShowCallButton: Bool = (
            SessionCall.isEnabled &&
            !isNoteToSelf &&
            threadVariant == .contact
        )
        self.stackViewLeadingConstraint.constant = (shouldShowCallButton ?
            ConversationTitleView.leftInsetWithCallButton :
            ConversationTitleView.leftInset
        )
        self.stackViewTrailingConstraint.constant = 0
    }
    
    // MARK: - Interaction
    
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        return self.labelCarouselView.scrollView
    }
}
