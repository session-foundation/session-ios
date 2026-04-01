// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Lucide
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
    private weak var navigationBar: UINavigationBar?
    
    /// The full width of the `navigationBar`
    private var availableWidth: CGFloat = 0
    private var leadingItems: [UIBarButtonItem] = []
    private var trailingItems: [UIBarButtonItem] = []
    
    override var intrinsicContentSize: CGSize {
        let titleHeight: CGFloat = titleLabel.sizeThatFits(
            CGSize(width: labelCarouselViewWidth.constant, height: .greatestFiniteMagnitude)
        ).height
        let subtitleHeight: CGFloat = {
            guard !labelCarouselView.isHidden else { return 0 }
            return labelCarouselView.intrinsicContentSize.height
        }()
        
        /// If the subtitleLabel (single item) is visible, measure it instead
        let singleSubtitleHeight: CGFloat = {
            guard !subtitleLabel.isHidden else { return 0 }
            return subtitleLabel.sizeThatFits(
                CGSize(width: labelCarouselViewWidth.constant, height: .greatestFiniteMagnitude)
            ).height
        }()
        
        let contentHeight: CGFloat = (titleHeight + max(subtitleHeight, singleSubtitleHeight) + stackView.spacing)
        return CGSize(width: UIView.noIntrinsicMetric, height: contentHeight)
    }
    
    private lazy var labelCarouselViewWidth = labelCarouselView
        .set(.width, to: 185)
        .setting(priority: .defaultHigh)
    
    public var currentLabelType: SessionLabelCarouselView.LabelType? {
        return self.labelCarouselView.currentLabelType
    }

    // MARK: - UI Components
    
    private lazy var stackViewMaxWidthConstraint: NSLayoutConstraint = stackView
        .set(.width, to: .greatestFiniteMagnitude)
        .setting(priority: .defaultHigh)
    private lazy var stackViewCenterConstraint: NSLayoutConstraint = stackView.center(.horizontal, in: self)
    
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
        result.setCompressionResistance(.horizontal, to: .defaultLow)
        result.setContentHugging(.horizontal, to: .defaultLow)
        
        return result
    }()
    
    private lazy var subtitleLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = SessionLabelCarouselView.font
        result.themeTextColor = .textPrimary
        result.lineBreakMode = .byWordWrapping
        result.numberOfLines = 2
        result.textAlignment = .center
        result.isHidden = true
        result.setCompressionResistance(.horizontal, to: .defaultLow)
        result.setContentHugging(.horizontal, to: .defaultLow)
        
        return result
    }()
    
    private lazy var labelCarouselView: SessionLabelCarouselView = {
        let result: SessionLabelCarouselView = SessionLabelCarouselView(using: dependencies)
        result.isHidden = true
        
        return result
    }()
    
    private lazy var stackView: UIStackView = {
        let result = UIStackView(arrangedSubviews: [ titleLabel, subtitleLabel, labelCarouselView ])
        result.axis = .vertical
        result.alignment = .center
        result.setCompressionResistance(.horizontal, to: .defaultLow)
        
        return result
    }()

    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        
        super.init(frame: .zero)
        
        setCompressionResistance(.horizontal, to: .defaultLow)
        addSubview(stackView)
        
        stackView.pin(.top, to: .top, of: self)
        stackView.pin(.bottom, to: .bottom, of: self)
        stackView.set(.width, lessThanOrEqualTo: .width, of: self)
        stackViewMaxWidthConstraint.isActive = true
        stackViewCenterConstraint.isActive = true
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
        
        guard let navigationBar, bounds.width > 0 else { return }
        
        let frameInNavBar: CGRect = convert(bounds, to: navigationBar)
        let spaceOnLeft: CGFloat = frameInNavBar.minX
        let spaceOnRight: CGFloat = max(0, (navigationBar.bounds.width - frameInNavBar.maxX))
        let navMidX: CGFloat = (navigationBar.bounds.width / 2)
        let maxWidth: CGFloat = max(0, (2 * min(navMidX - spaceOnLeft, navMidX - spaceOnRight)))
        
        /// If the title view is still animating into position (outside the nav bar bounds) reset to full width to avoid transient layouts
        /// breaking things, also don't bother updating if nothing changed
        guard
            frameInNavBar.minX >= 0 &&
            stackViewMaxWidthConstraint.constant != maxWidth
        else { return }
        
        stackViewMaxWidthConstraint.constant = maxWidth
        
        /// iOS 26 no longer seems to centre the title view to the screen (instead it's between the nav buttons) so we need to
        /// manually centre it
        if #available(iOS 26, *) {
            stackViewCenterConstraint.constant = ((spaceOnRight - spaceOnLeft) / 2)
        }
        
        labelCarouselViewWidth.constant = min(185, maxWidth)
        
        if !labelCarouselView.isHidden {
            labelCarouselView.update(
                with: labelCarouselView.originalLabelInfos,
                labelSize: CGSize(
                    width: labelCarouselViewWidth.constant,
                    height: 12
                ),
                shouldAutoScroll: false
            )
        }
    }
    
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let height: CGFloat = stackView.systemLayoutSizeFitting(
            CGSize(width: size.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        
        return CGSize(width: size.width, height: height)
    }
    
    @MainActor public func update(
        with viewModel: ConversationTitleViewModel,
        navigationBar: UINavigationBar?
    ) {
        self.navigationBar = navigationBar
        
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
        
        // No need to add themed subtitle content if we aren't adding the subtitle carousel
        guard shouldHaveSubtitle else {
            subtitleLabel.text = ""
            subtitleLabel.isHidden = true
            labelCarouselView.isHidden = true
            invalidateIntrinsicContentSize()
            setNeedsLayout()
            return
        }
        
        var labelInfos: [SessionLabelCarouselView.LabelInfo] = []
        
        if viewModel.isMuted {
            let notificationSettingsLabelString = ThemedAttributedString(
                string: NotificationsUI.mutePrefix.rawValue
            )
            .appending(string: "  ")
            .appending(string: "notificationsMuted".localized())
            .stylingNotificationPrefixesIfNeeded(fontSize: Values.miniFontSize)
            
            labelInfos.append(
                SessionLabelCarouselView.LabelInfo(
                    attributedText: notificationSettingsLabelString,
                    accessibility: nil, // TODO: Add accessibility
                    type: .notificationSettings
                )
            )
        }
        else if viewModel.onlyNotifyForMentions {
            let notificationSettingsLabelString = ThemedAttributedString(
                string: NotificationsUI.mentionPrefix.rawValue
            )
            .appending(string: "  ")
            .appending(string: "notificationsMentionsOnly".localized())
            .stylingNotificationPrefixesIfNeeded(fontSize: Values.miniFontSize)
            
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
        
        switch labelInfos.count {
            case 0:
                subtitleLabel.isHidden = true
                labelCarouselView.isHidden = true
                
            case 1:
                subtitleLabel.themeAttributedText = labelInfos[0].attributedText
                subtitleLabel.accessibilityIdentifier = labelInfos[0].accessibility?.identifier
                subtitleLabel.accessibilityLabel = labelInfos[0].accessibility?.label
                subtitleLabel.isHidden = false
                labelCarouselView.isHidden = true
                
            default:
                labelCarouselView.update(
                    with: labelInfos,
                    labelSize: CGSize(
                        width: labelCarouselViewWidth.constant,
                        height: 12
                    ),
                    shouldAutoScroll: false
                )
                subtitleLabel.isHidden = true
                labelCarouselView.isHidden = false
        }
        
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }
    
    // MARK: - Interaction
    
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if self.stackView.frame.contains(point) {
            return self.labelCarouselView.scrollView
        }
        return super.hitTest(point, with: event)
    }
}
