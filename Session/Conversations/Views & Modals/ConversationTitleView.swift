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
        return CGSize(
            width: UIView.noIntrinsicMetric,
            height: stackView.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).height
        )
    }
    
    private lazy var labelCarouselViewWidth = labelCarouselView.set(.width, to: 185)
    
    public var currentLabelType: SessionLabelCarouselView.LabelType? {
        return self.labelCarouselView.currentLabelType
    }

    // MARK: - UI Components
    
    private lazy var stackViewMaxWidthConstraint: NSLayoutConstraint = stackView.set(.width, to: .greatestFiniteMagnitude)
    
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
    
    private lazy var subtitleLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = SessionLabelCarouselView.font
        result.themeTextColor = .textPrimary
        result.lineBreakMode = .byWordWrapping
        result.numberOfLines = 2
        result.textAlignment = .center
        result.isHidden = true
        
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
        
        return result
    }()

    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        
        super.init(frame: .zero)
        
        addSubview(stackView)
        
        stackView.pin(.top, to: .top, of: self)
        stackView.pin(.bottom, to: .bottom, of: self)
        stackView.center(.horizontal, in: self)
        stackView.set(.width, lessThanOrEqualTo: .width, of: self)
        stackViewMaxWidthConstraint.isActive = true
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
        
        guard let navigationBar else { return }
        
        let frameInNavBar: CGRect = convert(bounds, to: navigationBar)
        let spaceOnLeft: CGFloat = frameInNavBar.minX
        let spaceOnRight: CGFloat = (navigationBar.bounds.width - frameInNavBar.maxX)
        let navMidX: CGFloat = (navigationBar.bounds.width / 2)
        
        stackViewMaxWidthConstraint.constant = max(0, (2 * min(navMidX - spaceOnLeft, navMidX - spaceOnRight)))
        stackView.transform = CGAffineTransform(
            translationX: ((spaceOnRight - spaceOnLeft) / 2),
            y: 0
        )
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
        self.labelCarouselView.isHidden = !shouldHaveSubtitle
        
        // No need to add themed subtitle content if we aren't adding the subtitle carousel
        guard shouldHaveSubtitle else {
            invalidateIntrinsicContentSize()
            setNeedsLayout()
            return
        }
        
        var labelInfos: [SessionLabelCarouselView.LabelInfo] = []
        
        if viewModel.isMuted {
            let notificationSettingsLabelString = ThemedAttributedString(
                string: NotificationsUI.mutePrefix.rawValue
            )
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
