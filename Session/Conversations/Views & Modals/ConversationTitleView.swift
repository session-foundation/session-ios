// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

// MARK: - ConversationTitleViewModel

struct ConversationTitleViewModel: Sendable, Equatable {
    let threadVariant: SessionThread.Variant
    let displayName: String
    let isNoteToSelf: Bool
    let isMessageRequest: Bool
    let showProBadge: Bool
    let isMuted: Bool
    let onlyNotifyForMentions: Bool
    let userCount: Int?
    let disappearingMessagesConfig: DisappearingMessagesConfiguration?
}

// MARK: - ConversationTitleView

final class ConversationTitleView: UIView {
    private static let leftInset: CGFloat = 8
    private static let leftInsetWithCallButton: CGFloat = 54
    
    private let dependencies: Dependencies
    private var oldSize: CGSize = .zero
    
    override var intrinsicContentSize: CGSize {
        return UIView.layoutFittingExpandedSize
    }
    
    private lazy var labelCarouselViewWidth = labelCarouselView.set(.width, to: 185)
    
    public var currentLabelType: SessionLabelCarouselView.LabelType? {
        return self.labelCarouselView.currentLabelType
    }

    // MARK: - UI Components
    
    private lazy var stackViewLeadingConstraint: NSLayoutConstraint = stackView.pin(.leading, to: .leading, of: self)
    private lazy var stackViewTrailingConstraint: NSLayoutConstraint = stackView.pin(.trailing, to: .trailing, of: self)
    
    private lazy var titleLabel: SessionLabelWithProBadge = {
        let result: SessionLabelWithProBadge = SessionLabelWithProBadge(
            proBadgeSize: .medium,
            withStretchingSpacer: false
        )
        result.accessibilityIdentifier = "Conversation header name"
        result.accessibilityLabel = "Conversation header name"
        result.isAccessibilityElement = true
        result.font = Fonts.Headings.H5
        result.themeTextColor = .textPrimary
        result.lineBreakMode = .byTruncatingTail
        result.isProBadgeHidden = true
        
        return result
    }()
    
    private lazy var labelCarouselView: SessionLabelCarouselView = {
        let result = SessionLabelCarouselView(using: dependencies)
        return result
    }()
    
    private lazy var stackView: UIStackView = {
        let result = UIStackView(arrangedSubviews: [ titleLabel, labelCarouselView ])
        result.axis = .vertical
        result.alignment = .center
        result.spacing = 2
        
        return result
    }()

    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        
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
    
    @MainActor public func update(with viewModel: ConversationTitleViewModel) {
        let shouldHaveSubtitle: Bool = (
            !viewModel.isMessageRequest && (
                viewModel.isMuted ||
                viewModel.onlyNotifyForMentions ||
                viewModel.userCount != nil ||
                viewModel.disappearingMessagesConfig?.isEnabled == true
            )
        )
        
        self.titleLabel.text = viewModel.displayName
        self.titleLabel.accessibilityLabel = viewModel.displayName
        self.titleLabel.font = (shouldHaveSubtitle ? Fonts.Headings.H6 : Fonts.Headings.H5)
        self.titleLabel.isProBadgeHidden = !viewModel.showProBadge
        self.labelCarouselView.isHidden = !shouldHaveSubtitle
        
        // Contact threads also have the call button to compensate for
        let shouldShowCallButton: Bool = (
            !viewModel.isNoteToSelf &&
            viewModel.threadVariant == .contact
        )
        self.stackViewLeadingConstraint.constant = (shouldShowCallButton ?
            ConversationTitleView.leftInsetWithCallButton :
            ConversationTitleView.leftInset
        )
        self.stackViewTrailingConstraint.constant = 0
        
        // No need to add themed subtitle content if we aren't adding the subtitle carousel
        guard shouldHaveSubtitle else { return }
        
        var labelInfos: [SessionLabelCarouselView.LabelInfo] = []
        
        if viewModel.isMuted {
            let notificationSettingsLabelString = ThemedAttributedString(
                string: FullConversationCell.mutePrefix,
                attributes: [
                    .font: UIFont(name: "ElegantIcons", size: 8) as Any,
                    .themeForegroundColor: ThemeValue.textPrimary
                ]
            )
            .appending(string: "notificationsMuted".localized())
            
            labelInfos.append(
                SessionLabelCarouselView.LabelInfo(
                    attributedText: notificationSettingsLabelString,
                    accessibility: nil, // TODO: Add accessibility
                    type: .notificationSettings
                )
            )
        }
        else if viewModel.onlyNotifyForMentions {
            let imageAttachment = NSTextAttachment()
            imageAttachment.image = UIImage(named: "NotifyMentions.png")?
                .withRenderingMode(.alwaysTemplate)
            imageAttachment.bounds = CGRect(
                x: 0,
                y: -2,
                width: Values.miniFontSize,
                height: Values.miniFontSize
            )
            
            let notificationSettingsLabelString = ThemedAttributedString(attachment: imageAttachment)
                .appending(string: "  ")
                .appending(string: "notificationsMentionsOnly".localized())
            
            labelInfos.append(
                SessionLabelCarouselView.LabelInfo(
                    attributedText: notificationSettingsLabelString,
                    accessibility: nil, // TODO: Add accessibility
                    type: .notificationSettings
                )
            )
        }
        
        if let userCount: Int = viewModel.userCount {
            switch viewModel.threadVariant {
                case .contact: break
                    
                case .legacyGroup, .group:
                    labelInfos.append(
                        SessionLabelCarouselView.LabelInfo(
                            attributedText: "members"
                                .putNumber(userCount)
                                .localizedFormatted(baseFont: .systemFont(ofSize: Values.miniFontSize)),
                            accessibility: nil, // TODO: Add accessibility
                            type: .userCount
                        )
                    )
                    
                case .community:
                    labelInfos.append(
                        SessionLabelCarouselView.LabelInfo(
                            attributedText: "membersActive"
                                .putNumber(userCount)
                                .localizedFormatted(baseFont: .systemFont(ofSize: Values.miniFontSize)),
                            accessibility: nil, // TODO: Add accessibility
                            type: .userCount
                        )
                    )
            }
        }
        
        if let config = viewModel.disappearingMessagesConfig, config.isEnabled == true {
            let imageAttachment = NSTextAttachment()
            imageAttachment.image = UIImage(systemName: "timer")?
                .withRenderingMode(.alwaysTemplate)
            imageAttachment.bounds = CGRect(
                x: 0,
                y: -2,
                width: Values.miniFontSize,
                height: Values.miniFontSize
            )
            
            labelInfos.append(
                SessionLabelCarouselView.LabelInfo(
                    attributedText: ThemedAttributedString(attachment: imageAttachment)
                        .appending(string: " ")
                        .appending(
                            string: (config.type ?? .unknown)
                                .localizedState(
                                    durationString: config.durationString
                                )
                        ),
                    accessibility: Accessibility(
                        identifier: "Disappearing messages type and time",
                        label: "Disappearing messages type and time"
                    ),
                    type: .disappearingMessageSetting
                )
            )
        }
        
        labelCarouselView.update(
            with: labelInfos,
            labelSize: CGSize(
                width: labelCarouselViewWidth.constant,
                height: 12
            ),
            shouldAutoScroll: false
        )
        labelCarouselView.isHidden = (labelInfos.count == 0)
    }
    
    // MARK: - Interaction
    
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if self.stackView.frame.contains(point) {
            return self.labelCarouselView.scrollView
        }
        return super.hitTest(point, with: event)
    }
}
