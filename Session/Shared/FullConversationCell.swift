// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Lucide
import SessionUIKit
import SignalUtilitiesKit
import SessionMessagingKit
import SessionUtilitiesKit

public final class FullConversationCell: UITableViewCell, SwipeActionOptimisticCell {
    public static let unreadCountViewSize: CGFloat = 20
    private static let statusIndicatorSize: CGFloat = 14
    private static let displayNameFont: UIFont = .boldSystemFont(ofSize: Values.mediumFontSize)
    private static let snippetFont: UIFont = .systemFont(ofSize: Values.smallFontSize)
    
    // MARK: - UI
    
    private let accentLineView: UIView = {
        let result: UIView = UIView()
        result.themeBackgroundColor = .conversationButton_unreadStripBackground
        result.alpha = 0
        
        return result
    }()

    private lazy var profilePictureView: ProfilePictureView = ProfilePictureView(
        size: .list,
        dataManager: nil
    )

    private lazy var displayNameLabel: SessionLabelWithProBadge = {
        let result: SessionLabelWithProBadge = SessionLabelWithProBadge(
            proBadgeSize: .small,
            withStretchingSpacer: false
        )
        result.font = FullConversationCell.displayNameFont
        result.themeTextColor = .textPrimary
        result.lineBreakMode = .byTruncatingTail
        result.isProBadgeHidden = true
        
        return result
    }()

    private lazy var unreadCountView: UIView = {
        let result: UIView = UIView()
        result.clipsToBounds = true
        result.themeBackgroundColor = .conversationButton_unreadBubbleBackground
        result.layer.cornerRadius = (FullConversationCell.unreadCountViewSize / 2)
        result.set(.width, greaterThanOrEqualTo: FullConversationCell.unreadCountViewSize)
        result.set(.height, to: FullConversationCell.unreadCountViewSize)
        
        return result
    }()

    private lazy var unreadCountLabel: UILabel = {
        let result: UILabel = UILabel()
        result.setContentHuggingPriority(.required, for: .horizontal)
        result.setContentCompressionResistancePriority(.required, for: .horizontal)
        result.font = .boldSystemFont(ofSize: Values.verySmallFontSize)
        result.themeTextColor = .conversationButton_unreadBubbleText
        result.textAlignment = .center
        
        return result
    }()
    
    private lazy var unreadImageView: UIView = {
        let iconHeight: CGFloat = 12
        let indicatorSize: CGFloat = 6
        
        let result: UIView = UIView()
        
        let imageView: UIImageView = UIImageView(image: UIImage(systemName: "envelope"))
        imageView.contentMode = .scaleAspectFit
        imageView.themeTintColor = .textPrimary
        result.addSubview(imageView)
        
        // Note: We add a 2 inset to align the bottom of the image with the bottom of the text (looks
        // off otherwise)
        imageView.pin(.top, to: .top, of: result, withInset: 2)
        imageView.pin(.leading, to: .leading, of: result)
        imageView.pin(.trailing, to: .trailing, of: result)
        imageView.pin(.bottom, to: .bottom, of: result)
        
        // Note: For some weird reason if we dont '+ 4' here the height ends up getting set to '8'
        imageView.set(.height, to: (iconHeight + 4))
        imageView.set(.width, to: ((imageView.image?.size.width ?? 1) / (imageView.image?.size.height ?? 1) * iconHeight))
        
        let indicatorBackgroundView: UIView = UIView()
        indicatorBackgroundView.themeBackgroundColor = .conversationButton_unreadBackground
        indicatorBackgroundView.layer.cornerRadius = (indicatorSize / 2)
        result.addSubview(indicatorBackgroundView)

        indicatorBackgroundView.set(.width, to: indicatorSize)
        indicatorBackgroundView.set(.height, to: indicatorSize)
        indicatorBackgroundView.pin(.top, to: .top, of: result, withInset: 1)
        indicatorBackgroundView.pin(.trailing, to: .trailing, of: result, withInset: 1)
        
        let indicatorView: UIView = UIView()
        indicatorView.themeBackgroundColor = .conversationButton_unreadBubbleBackground
        indicatorView.layer.cornerRadius = ((indicatorSize - 2) / 2)
        result.addSubview(indicatorView)

        indicatorView.set(.width, to: (indicatorSize - 2))
        indicatorView.set(.height, to: (indicatorSize - 2))
        indicatorView.center(in: indicatorBackgroundView)
        
        return result
    }()

    private lazy var hasMentionView: UIView = {
        let result: UIView = UIView()
        result.clipsToBounds = true
        result.themeBackgroundColor = .conversationButton_unreadBubbleBackground
        result.layer.cornerRadius = (FullConversationCell.unreadCountViewSize / 2)
        result.set(.width, to: FullConversationCell.unreadCountViewSize)
        result.set(.height, to: FullConversationCell.unreadCountViewSize)
        
        return result
    }()

    private lazy var hasMentionLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = .boldSystemFont(ofSize: Values.verySmallFontSize)
        result.themeTextColor = .conversationButton_unreadBubbleText
        result.text = "@" // stringlint:ignore
        result.textAlignment = .center
        
        return result
    }()

    private lazy var isPinnedIcon: UIImageView = {
        let result: UIImageView = UIImageView(
            image: UIImage(named: "Pin")?
                .withRenderingMode(.alwaysTemplate)
        )
        result.clipsToBounds = true
        result.themeTintColor = .textSecondary
        result.contentMode = .scaleAspectFit
        result.set(.width, to: FullConversationCell.unreadCountViewSize)
        result.set(.height, to: FullConversationCell.unreadCountViewSize)
        
        return result
    }()

    private lazy var timestampLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = .systemFont(ofSize: Values.smallFontSize)
        result.themeTextColor = .textSecondary
        result.lineBreakMode = .byTruncatingTail
        result.alpha = Values.lowOpacity
        
        return result
    }()

    private lazy var snippetLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = FullConversationCell.snippetFont
        result.themeTextColor = .textPrimary
        result.lineBreakMode = .byTruncatingTail
        
        return result
    }()

    private lazy var typingIndicatorView = TypingIndicatorView()

    private lazy var statusIndicatorView: UIImageView = {
        let result: UIImageView = UIImageView()
        result.clipsToBounds = true
        result.contentMode = .scaleAspectFit
        
        return result
    }()

    private lazy var topLabelStackView: UIStackView = {
        let result: UIStackView = UIStackView()
        result.axis = .horizontal
        result.alignment = .center
        result.spacing = Values.smallSpacing / 2 // Effectively Values.smallSpacing because there'll be spacing before and after the invisible spacer
        
        return result
    }()

    private lazy var bottomLabelStackView: UIStackView = {
        let result: UIStackView = UIStackView()
        result.axis = .horizontal
        result.alignment = .center
        result.spacing = Values.smallSpacing / 2 // Effectively Values.smallSpacing because there'll be spacing before and after the invisible spacer
        
        return result
    }()

    // MARK: - Initialization
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        
        setUpViewHierarchy()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpViewHierarchy()
    }

    private func setUpViewHierarchy() {
        let cellHeight: CGFloat = 68
        
        // Background color
        themeBackgroundColor = .conversationButton_background
        
        // Highlight color
        let selectedBackgroundView = UIView()
        selectedBackgroundView.themeBackgroundColor = .highlighted(.conversationButton_background)
        self.selectedBackgroundView = selectedBackgroundView
        
        // Accent line view
        accentLineView.set(.width, to: Values.accentLineThickness)
        accentLineView.set(.height, to: cellHeight)
        
        // Unread count view
        unreadCountView.addSubview(unreadCountLabel)
        unreadCountView.setCompressionResistance(to: .required)
        unreadCountLabel.pin([ VerticalEdge.top, VerticalEdge.bottom ], to: unreadCountView)
        unreadCountView.pin(.leading, to: .leading, of: unreadCountLabel, withInset: -4)
        unreadCountView.pin(.trailing, to: .trailing, of: unreadCountLabel, withInset: 4)
        
        // Has mention view
        hasMentionView.addSubview(hasMentionLabel)
        hasMentionLabel.setCompressionResistance(to: .required)
        hasMentionLabel.pin(to: hasMentionView)
        
        // Label stack view
        let topLabelSpacer = UIView.hStretchingSpacer()
        [ displayNameLabel, isPinnedIcon, unreadCountView, unreadImageView, hasMentionView, topLabelSpacer, timestampLabel ].forEach{ view in
            topLabelStackView.addArrangedSubview(view)
        }
        
        let snippetLabelContainer = UIView()
        snippetLabelContainer.addSubview(snippetLabel)
        snippetLabelContainer.addSubview(typingIndicatorView)
        
        let bottomLabelSpacer = UIView.hStretchingSpacer()
        [ snippetLabelContainer, bottomLabelSpacer, statusIndicatorView ].forEach{ view in
            bottomLabelStackView.addArrangedSubview(view)
        }
        
        let labelContainerView = UIStackView(arrangedSubviews: [ topLabelStackView, bottomLabelStackView ])
        labelContainerView.axis = .vertical
        labelContainerView.alignment = .fill
        labelContainerView.spacing = 6
        labelContainerView.isUserInteractionEnabled = false
        
        // Main stack view
        let stackView = UIStackView(arrangedSubviews: [ accentLineView, profilePictureView, labelContainerView ])
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = Values.mediumSpacing
        contentView.addSubview(stackView)
        
        // Constraints
        accentLineView.pin(.top, to: .top, of: contentView)
        accentLineView.pin(.bottom, to: .bottom, of: contentView)
        timestampLabel.setContentCompressionResistancePriority(.required, for: NSLayoutConstraint.Axis.horizontal)
        
        // HACK: The 4 lines below are part of a workaround for a weird layout bug
        topLabelStackView.set(.height, to: 20)
        topLabelSpacer.set(.height, to: 20)
        
        bottomLabelStackView.set(.height, to: 18)
        bottomLabelSpacer.set(.height, to: 18)
        
        statusIndicatorView.set(.width, to: FullConversationCell.statusIndicatorSize)
        statusIndicatorView.set(.height, to: FullConversationCell.statusIndicatorSize)
        
        snippetLabel.pin(to: snippetLabelContainer)
        
        typingIndicatorView.pin(.leading, to: .leading, of: snippetLabelContainer)
        typingIndicatorView.centerYAnchor.constraint(equalTo: snippetLabel.centerYAnchor).isActive = true
        
        stackView.pin([ UIView.VerticalEdge.bottom, UIView.VerticalEdge.top, UIView.HorizontalEdge.leading ], to: contentView)
        stackView.pin(.trailing, to: .trailing, of: contentView, withInset: -Values.mediumSpacing)
    }
    
    // MARK: - Content
    
    public override func prepareForReuse() {
        super.prepareForReuse()
        
        /// Need to reset the fonts as it seems that the `.font` values can end up using a styled font from the attributed text
        displayNameLabel.font = FullConversationCell.displayNameFont
        snippetLabel.font = FullConversationCell.snippetFont
    }
    
    // MARK: --Search Results
    public func updateForDefaultContacts(with cellViewModel: ConversationInfoViewModel, using dependencies: Dependencies) {
        profilePictureView.setDataManager(dependencies[singleton: .imageDataManager])
        profilePictureView.update(
            publicKey: cellViewModel.id,
            threadVariant: cellViewModel.variant,
            displayPictureUrl: cellViewModel.displayPictureUrl,
            profile: cellViewModel.profile,
            additionalProfile: cellViewModel.additionalProfile,
            using: dependencies
        )
        
        isPinnedIcon.isHidden = true
        unreadCountView.isHidden = true
        unreadImageView.isHidden = true
        hasMentionView.isHidden = true
        timestampLabel.isHidden = true
        timestampLabel.text = cellViewModel.dateForDisplay
        bottomLabelStackView.isHidden = true
        displayNameLabel.themeAttributedText = cellViewModel.displayName.formatted(baseFont: displayNameLabel.font)
        displayNameLabel.isProBadgeHidden = !cellViewModel.shouldShowProBadge
    }
    
    public func updateForMessageSearchResult(
        with cellViewModel: ConversationInfoViewModel,
        searchText: String,
        using dependencies: Dependencies
    ) {
        profilePictureView.setDataManager(dependencies[singleton: .imageDataManager])
        profilePictureView.update(
            publicKey: cellViewModel.id,
            threadVariant: cellViewModel.variant,
            displayPictureUrl: cellViewModel.displayPictureUrl,
            profile: cellViewModel.profile,
            additionalProfile: cellViewModel.additionalProfile,
            using: dependencies
        )
        
        isPinnedIcon.isHidden = true
        unreadCountView.isHidden = true
        unreadImageView.isHidden = true
        hasMentionView.isHidden = true
        timestampLabel.isHidden = false
        timestampLabel.text = cellViewModel.dateForDisplay
        bottomLabelStackView.isHidden = false
        displayNameLabel.themeAttributedText = cellViewModel.displayName.formatted(baseFont: displayNameLabel.font)
        displayNameLabel.isProBadgeHidden = !cellViewModel.shouldShowProBadge
        snippetLabel.themeAttributedText = cellViewModel.messageSnippet?
            .formatted(baseFont: snippetLabel.font)
            .stylingNotificationPrefixesIfNeeded(fontSize: Values.verySmallFontSize)
    }
    
    public func updateForContactAndGroupSearchResult(
        with cellViewModel: ConversationInfoViewModel,
        searchText: String,
        using dependencies: Dependencies
    ) {
        profilePictureView.setDataManager(dependencies[singleton: .imageDataManager])
        profilePictureView.update(
            publicKey: cellViewModel.id,
            threadVariant: cellViewModel.variant,
            displayPictureUrl: cellViewModel.displayPictureUrl,
            profile: cellViewModel.profile,
            additionalProfile: cellViewModel.additionalProfile,
            using: dependencies
        )
        
        isPinnedIcon.isHidden = true
        unreadCountView.isHidden = true
        unreadImageView.isHidden = true
        hasMentionView.isHidden = true
        timestampLabel.isHidden = true
        displayNameLabel.themeAttributedText = cellViewModel.displayName.formatted(baseFont: displayNameLabel.font)
        displayNameLabel.isProBadgeHidden = !cellViewModel.shouldShowProBadge
        
        switch cellViewModel.variant {
            case .contact, .community: bottomLabelStackView.isHidden = true
                
            case .legacyGroup, .group:
                bottomLabelStackView.isHidden = cellViewModel.memberNames.isEmpty
                snippetLabel.themeAttributedText = cellViewModel.memberNames
                    .formatted(baseFont: snippetLabel.font)
        }
    }

    // MARK: --Standard
    
    public func update(with cellViewModel: ConversationInfoViewModel, using dependencies: Dependencies) {
        let unreadCount: Int = cellViewModel.unreadCount
        let threadIsUnread: Bool = (
            unreadCount > 0 || (
                cellViewModel.id != cellViewModel.userSessionId.hexString &&
                cellViewModel.wasMarkedUnread
            )
        )
        let themeBackgroundColor: ThemeValue = (threadIsUnread ?
            .conversationButton_unreadBackground :
            .conversationButton_background
        )
        self.themeBackgroundColor = themeBackgroundColor
        self.selectedBackgroundView?.themeBackgroundColor = .highlighted(themeBackgroundColor)
        
        accentLineView.alpha = (unreadCount > 0 ? 1 : 0)
        isPinnedIcon.isHidden = (cellViewModel.pinnedPriority <= LibSession.visiblePriority)
        unreadCountView.isHidden = (unreadCount <= 0)
        unreadImageView.isHidden = (!unreadCountView.isHidden || !threadIsUnread)
        unreadCountLabel.text = (unreadCount <= 0 ?
            "" :
            (unreadCount < 10000 ? "\(unreadCount)" : "9999+") // stringlint:ignore
        )
        unreadCountLabel.font = .boldSystemFont(
            ofSize: (unreadCount < 10000 ? Values.verySmallFontSize : 8)
        )
        hasMentionView.isHidden = !(
            (cellViewModel.unreadMentionCount > 0) && (
                cellViewModel.variant == .legacyGroup ||
                cellViewModel.variant == .group ||
                cellViewModel.variant == .community
            )
        )
        profilePictureView.setDataManager(dependencies[singleton: .imageDataManager])
        profilePictureView.update(
            publicKey: cellViewModel.id,
            threadVariant: cellViewModel.variant,
            displayPictureUrl: cellViewModel.displayPictureUrl,
            profile: cellViewModel.profile,
            additionalProfile: cellViewModel.additionalProfile,
            using: dependencies
        )
        displayNameLabel.themeAttributedText = cellViewModel.displayName.formatted(baseFont: displayNameLabel.font)
        displayNameLabel.isProBadgeHidden = !cellViewModel.shouldShowProBadge
        timestampLabel.text = cellViewModel.dateForDisplay
        
        if cellViewModel.isTyping {
            snippetLabel.text = ""
            typingIndicatorView.isHidden = false
            typingIndicatorView.startAnimation()
        }
        else {
            displayNameLabel.themeTextColor = {
                guard cellViewModel.lastInteraction?.variant != .infoGroupCurrentUserLeaving else {
                    return .textSecondary
                }
                
                return .textPrimary
            }()
            typingIndicatorView.isHidden = true
            typingIndicatorView.stopAnimation()
            snippetLabel.themeAttributedText = cellViewModel.messageSnippet?
                .formatted(baseFont: snippetLabel.font)
                .stylingNotificationPrefixesIfNeeded(fontSize: Values.verySmallFontSize)
        }
        
        let stateInfo = cellViewModel.lastInteraction?.state.statusIconInfo(
            variant: (cellViewModel.lastInteraction?.variant ?? .standardOutgoing),
            hasBeenReadByRecipient: (cellViewModel.lastInteraction?.hasBeenReadByRecipient == true),
            hasAttachments: (cellViewModel.lastInteraction?.hasAttachments == true)
        )
        statusIndicatorView.image = stateInfo?.image
        statusIndicatorView.themeTintColor = stateInfo?.themeTintColor
        statusIndicatorView.isHidden = (
            cellViewModel.lastInteraction?.variant != .standardOutgoing &&
            cellViewModel.lastInteraction?.state != .localOnly &&
            cellViewModel.lastInteraction?.state != .deleted
        )
    }
    
    // MARK: - SwipeActionOptimisticCell
    
    public func optimisticUpdate(
        isMuted: Bool?,
        isPinned: Bool?,
        hasUnread: Bool?
    ) {
        // Note: This will result in the snippet being out of sync while the swipe action animation completes,
        // this means if the day/night mode changes while the animation is happening then the below optimistic
        // update might get reset (this should be rare and is a relatively minor bug so can be left in)
        if let isMuted: Bool = isMuted {
            let attrString: NSAttributedString = (self.snippetLabel.attributedText ?? NSAttributedString())
            let hasMutePrefix: Bool = attrString.string.starts(with: NotificationsUI.mutePrefix.rawValue)
            
            switch (isMuted, hasMutePrefix) {
                case (true, false):
                    snippetLabel.themeAttributedText = ThemedAttributedString(
                        string: NotificationsUI.mutePrefix.rawValue,
                        attributes: Lucide.attributes(for: .systemFont(ofSize: Values.verySmallFontSize))
                    )
                    .appending(NSAttributedString(string: " "))
                    .appending(attrString.adding(attributes: [.font: FullConversationCell.snippetFont]))
                    
                case (false, true):
                    /// Need to remove the space as well
                    let location: Int = (NotificationsUI.mutePrefix.rawValue.count + 1)
                    snippetLabel.attributedText = attrString
                        .attributedSubstring(
                            from: NSRange(location: location, length: (attrString.length - location))
                        )
                    
                default: break
            }
        }
        
        if let isPinned: Bool = isPinned {
            isPinnedIcon.isHidden = !isPinned
        }
        
        if let hasUnread: Bool = hasUnread {
            if hasUnread {
                unreadCountView.isHidden = false
                unreadCountLabel.text = "1" // stringlint:ignore
                unreadCountLabel.font = .boldSystemFont(ofSize: Values.verySmallFontSize)
                accentLineView.alpha = 1
            } else {
                unreadCountView.isHidden = true
                accentLineView.alpha = 0
            }
        }
    }
}
