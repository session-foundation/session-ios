// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SignalUtilitiesKit
import SessionUtilitiesKit
import SessionMessagingKit

final class VisibleMessageCell: MessageCell, TappableLabelDelegate {
    private static let maxNumberOfLinesAfterTruncation: Int = 25
    
    private var isHandlingLongPress: Bool = false
    private var previousX: CGFloat = 0
    
    var albumView: MediaAlbumView?
    var quoteView: QuoteView?
    var linkPreviewView: LinkPreviewView?
    var documentView: DocumentView?
    var bodyTappableLabel: TappableLabel?
    var bodyTappableLabelHeight: CGFloat = 0
    var bodayTappableLabelHeightConstraint: NSLayoutConstraint?
    var bodyContainerStackView: UIStackView?
    var voiceMessageView: VoiceMessageView?
    var audioStateChanged: ((TimeInterval, Bool) -> ())?
    
    override var contextSnapshotView: UIView? { return snContentView }
    
    // Constraints
    internal lazy var authorLabelTopConstraint = authorLabel.pin(.top, to: .top, of: self)
    private lazy var authorLabelHeightConstraint = authorLabel.set(.height, to: 0)
    private lazy var profilePictureViewLeadingConstraint = profilePictureView.pin(.leading, to: .leading, of: self, withInset: VisibleMessageCell.groupThreadHSpacing)
    internal lazy var contentViewLeadingConstraint1 = snContentView.pin(.leading, to: .trailing, of: profilePictureView, withInset: VisibleMessageCell.groupThreadHSpacing)
    private lazy var contentViewLeadingConstraint2 = snContentView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: VisibleMessageCell.gutterSize)
    private lazy var contentViewTopConstraint = snContentView.pin(.top, to: .bottom, of: authorLabel, withInset: VisibleMessageCell.authorLabelBottomSpacing)
    internal lazy var contentViewTrailingConstraint1 = snContentView.pin(.trailing, to: .trailing, of: self, withInset: -VisibleMessageCell.contactThreadHSpacing)
    private lazy var contentViewTrailingConstraint2 = snContentView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -VisibleMessageCell.gutterSize)
    private lazy var contentBottomConstraint = snContentView.bottomAnchor
        .constraint(lessThanOrEqualTo: self.bottomAnchor, constant: -1)
    
    private lazy var underBubbleStackViewIncomingLeadingConstraint: NSLayoutConstraint = underBubbleStackView.pin(.leading, to: .leading, of: snContentView)
    private lazy var underBubbleStackViewIncomingTrailingConstraint: NSLayoutConstraint = underBubbleStackView.pin(.trailing, to: .trailing, of: self, withInset: -VisibleMessageCell.contactThreadHSpacing)
    private lazy var underBubbleStackViewOutgoingLeadingConstraint: NSLayoutConstraint = underBubbleStackView.pin(.leading, to: .leading, of: self, withInset: VisibleMessageCell.contactThreadHSpacing)
    private lazy var underBubbleStackViewOutgoingTrailingConstraint: NSLayoutConstraint = underBubbleStackView.pin(.trailing, to: .trailing, of: snContentView)
    private lazy var underBubbleStackViewNoHeightConstraint: NSLayoutConstraint = underBubbleStackView.set(.height, to: 0)
    
    private lazy var timerViewOutgoingMessageConstraint = timerView.pin(.trailing, to: .trailing, of: messageStatusContainerView)
    private lazy var timerViewIncomingMessageConstraint = timerView.pin(.leading, to: .leading, of: messageStatusContainerView)
    private lazy var messageStatusLabelOutgoingMessageConstraint = messageStatusLabel.pin(.trailing, to: .leading, of: timerView, withInset: -2)
    private lazy var messageStatusLabelIncomingMessageConstraint = messageStatusLabel.pin(.leading, to: .trailing, of: timerView, withInset: 2)

    private lazy var panGestureRecognizer: UIPanGestureRecognizer = {
        let result = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        result.delegate = self
        return result
    }()
    
    // MARK: - UI Components
    
    private lazy var viewsToMoveForReply: [UIView] = [
        snContentView,
        profilePictureView,
        replyButton,
        timerView,
        messageStatusContainerView,
        reactionContainerView
    ]
    
    private lazy var profilePictureView: ProfilePictureView = ProfilePictureView(
        size: .message,
        dataManager: nil,
        currentUserSessionProState: nil
    )
    
    lazy var bubbleBackgroundView: UIView = {
        let result = UIView()
        result.layer.cornerRadius = VisibleMessageCell.largeCornerRadius
        return result
    }()

    lazy var bubbleView: UIView = {
        let result = UIView()
        result.clipsToBounds = true
        result.layer.cornerRadius = VisibleMessageCell.largeCornerRadius
        result.set(.width, greaterThanOrEqualTo: VisibleMessageCell.largeCornerRadius * 2)
        return result
    }()
    
    private lazy var authorLabel: UILabel = {
        let result = UILabel()
        result.font = .boldSystemFont(ofSize: Values.smallFontSize)
        return result
    }()

    lazy var snContentView: UIStackView = {
        let result = UIStackView(arrangedSubviews: [])
        result.axis = .vertical
        result.spacing = Values.verySmallSpacing
        result.alignment = .leading
        return result
    }()

    private lazy var replyButton: UIView = {
        let result = UIView()
        let size = VisibleMessageCell.replyButtonSize + 8
        result.set(.width, to: size)
        result.set(.height, to: size)
        result.themeBorderColor = .textPrimary
        result.layer.borderWidth = 1
        result.layer.cornerRadius = (size / 2)
        result.layer.masksToBounds = true
        result.alpha = 0
        
        return result
    }()

    private lazy var replyIconImageView: UIImageView = {
        let result = UIImageView()
        let size = VisibleMessageCell.replyButtonSize
        result.set(.width, to: size)
        result.set(.height, to: size)
        result.image = UIImage(named: "ic_reply")?.withRenderingMode(.alwaysTemplate)
        result.themeTintColor = .textPrimary
        
        return result
    }()
    
    private lazy var readMoreButton: UILabel = {
        let result = UILabel()
        result.font = .boldSystemFont(ofSize: Values.smallFontSize)
        result.themeTextColor = .textPrimary
        result.textAlignment = .natural
        result.text = "messageBubbleReadMore".localized()
        
        return result
    }()

    private lazy var timerView: DisappearingMessageTimerView = DisappearingMessageTimerView()
    
    lazy var underBubbleStackView: UIStackView = {
        let result = UIStackView(arrangedSubviews: [])
        result.setContentHuggingPriority(.required, for: .vertical)
        result.setContentCompressionResistancePriority(.required, for: .vertical)
        result.axis = .vertical
        result.spacing = Values.verySmallSpacing
        result.alignment = .trailing
        
        return result
    }()

    private lazy var reactionContainerView = ReactionContainerView()
    
    internal lazy var messageStatusContainerView: UIView = {
        let result = UIView()
        
        return result
    }()
    
    internal lazy var messageStatusLabel: UILabel = {
        let result = UILabel()
        result.accessibilityIdentifier = "Message sent status"
        result.accessibilityLabel = "Message sent status"
        result.font = .systemFont(ofSize: Values.verySmallFontSize)
        result.themeTextColor = .messageBubble_deliveryStatus  
        
        return result
    }()
    
    internal lazy var messageStatusImageView: UIImageView = {
        let result = UIImageView()
        result.accessibilityIdentifier = "Message sent status tick"
        result.accessibilityLabel = "Message sent status tick"
        result.contentMode = .scaleAspectFit
        result.themeTintColor = .messageBubble_deliveryStatus
        
        return result
    }()
    
    internal lazy var messageStatusLabelPaddingView: UIView = UIView()

    // MARK: - Settings
    
    private static let messageStatusImageViewSize: CGFloat = 12
    private static let authorLabelBottomSpacing: CGFloat = 4
    private static let groupThreadHSpacing: CGFloat = 12
    private static let authorLabelInset: CGFloat = 12
    private static let replyButtonSize: CGFloat = 24
    private static let maxBubbleTranslationX: CGFloat = 40
    private static let swipeToReplyThreshold: CGFloat = 110
    static let smallCornerRadius: CGFloat = 4
    static let largeCornerRadius: CGFloat = 18
    static let contactThreadHSpacing = Values.mediumSpacing

    static var gutterSize: CGFloat = {
        var result = groupThreadHSpacing + ProfilePictureView.Size.message.viewSize + groupThreadHSpacing
        
        if UIDevice.current.isIPad {
            result += 168
        }
        
        return result
    }()
    
    static var leftGutterSize: CGFloat { groupThreadHSpacing + ProfilePictureView.Size.message.viewSize + groupThreadHSpacing }
    
    // MARK: Direction & Position
    
    enum Direction { case incoming, outgoing }

    // MARK: - Lifecycle
    
    override func setUpViewHierarchy() {
        super.setUpViewHierarchy()
        
        // Author label
        addSubview(authorLabel)
        authorLabelTopConstraint.isActive = true
        authorLabelHeightConstraint.isActive = true
        
        // Profile picture view
        addSubview(profilePictureView)
        profilePictureViewLeadingConstraint.isActive = true
        
        // Content view
        addSubview(snContentView)
        contentViewLeadingConstraint1.isActive = true
        contentViewTopConstraint.isActive = true
        contentViewTrailingConstraint1.isActive = true
        snContentView.pin(.bottom, to: .bottom, of: profilePictureView)
        
        // Bubble background view
        bubbleBackgroundView.addSubview(bubbleView)
        bubbleView.pin(to: bubbleBackgroundView)
        
        // Reply button
        addSubview(replyButton)
        replyButton.addSubview(replyIconImageView)
        replyIconImageView.center(in: replyButton)
        replyButton.pin(.leading, to: .trailing, of: snContentView, withInset: Values.smallSpacing)
        replyButton.center(.vertical, in: snContentView)
        
        // Remaining constraints
        authorLabel.pin(.leading, to: .leading, of: snContentView, withInset: VisibleMessageCell.authorLabelInset)
        authorLabel.pin(.trailing, to: .trailing, of: self, withInset: -Values.mediumSpacing)
        
        // Under bubble content
        addSubview(underBubbleStackView)
        underBubbleStackView.pin(.top, to: .bottom, of: snContentView, withInset: Values.verySmallSpacing)
        underBubbleStackView.pin(.bottom, to: .bottom, of: self)
        
        underBubbleStackView.addArrangedSubview(reactionContainerView)
        underBubbleStackView.addArrangedSubview(messageStatusContainerView)
        underBubbleStackView.addArrangedSubview(messageStatusLabelPaddingView)
        
        messageStatusContainerView.addSubview(messageStatusLabel)
        messageStatusContainerView.addSubview(messageStatusImageView)
        messageStatusContainerView.addSubview(timerView)
        
        reactionContainerView.widthAnchor
            .constraint(lessThanOrEqualTo: underBubbleStackView.widthAnchor)
            .isActive = true
        messageStatusImageView.pin(.top, to: .top, of: messageStatusContainerView)
        messageStatusImageView.pin(.bottom, to: .bottom, of: messageStatusContainerView)
        messageStatusImageView.pin(.trailing, to: .trailing, of: messageStatusContainerView)
        messageStatusImageView.set(.width, to: VisibleMessageCell.messageStatusImageViewSize)
        messageStatusImageView.set(.height, to: VisibleMessageCell.messageStatusImageViewSize)
        timerView.pin(.top, to: .top, of: messageStatusContainerView)
        timerView.pin(.bottom, to: .bottom, of: messageStatusContainerView)
        timerView.set(.width, to: VisibleMessageCell.messageStatusImageViewSize)
        timerView.set(.height, to: VisibleMessageCell.messageStatusImageViewSize)
        messageStatusLabel.center(.vertical, in: messageStatusContainerView)
        messageStatusLabelPaddingView.pin(.leading, to: .leading, of: messageStatusContainerView)
        messageStatusLabelPaddingView.pin(.trailing, to: .trailing, of: messageStatusContainerView)
    }

    override func setUpGestureRecognizers() {
        let longPressRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
        addGestureRecognizer(longPressRecognizer)
        
        let tapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tapGestureRecognizer.numberOfTapsRequired = 1
        addGestureRecognizer(tapGestureRecognizer)
        
        let doubleTapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTapGestureRecognizer.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTapGestureRecognizer)
        tapGestureRecognizer.require(toFail: doubleTapGestureRecognizer)
    }

    // MARK: - Updating
    
    override func update(
        with cellViewModel: MessageViewModel,
        playbackInfo: ConversationViewModel.PlaybackInfo?,
        showExpandedReactions: Bool,
        shouldExpanded: Bool,
        lastSearchText: String?,
        using dependencies: Dependencies
    ) {
        self.dependencies = dependencies
        self.viewModel = cellViewModel
        
        // We want to add spacing between "clusters" of messages to indicate that time has
        // passed (even if there wasn't enough time to warrant showing a date header)
        let shouldAddTopInset: Bool = (
            !cellViewModel.shouldShowDateHeader &&
            cellViewModel.previousVariant?.isInfoMessage != true && (
                cellViewModel.positionInCluster == .top ||
                cellViewModel.isOnlyMessageInCluster
            )
        )
        let isGroupThread: Bool = (
            cellViewModel.threadVariant == .community ||
            cellViewModel.threadVariant == .legacyGroup ||
            cellViewModel.threadVariant == .group
        )
        
        // Profile picture view (should always be handled as a standard 'contact' profile picture)
        let profileShouldBeVisible: Bool = (
            cellViewModel.canHaveProfile &&
            cellViewModel.shouldShowProfile &&
            cellViewModel.profile != nil
        )
        profilePictureViewLeadingConstraint.constant = (isGroupThread ? VisibleMessageCell.groupThreadHSpacing : 0)
        profilePictureView.isHidden = !cellViewModel.canHaveProfile
        profilePictureView.alpha = (profileShouldBeVisible ? 1 : 0)
        profilePictureView.setDataManager(dependencies[singleton: .imageDataManager])
        profilePictureView.setCurrentUserSessionProState(dependencies[singleton: .sessionProState])
        profilePictureView.update(
            publicKey: cellViewModel.authorId,
            threadVariant: .contact,    // Always show the display picture in 'contact' mode
            displayPictureUrl: nil,
            profile: cellViewModel.profile,
            profileIcon: (cellViewModel.isSenderModeratorOrAdmin ? .crown : .none),
            using: dependencies
        )
       
        // Bubble view
        contentViewLeadingConstraint1.isActive = cellViewModel.variant.isIncoming
        contentViewLeadingConstraint1.constant = (isGroupThread ? VisibleMessageCell.groupThreadHSpacing : VisibleMessageCell.contactThreadHSpacing)
        contentViewLeadingConstraint2.isActive = cellViewModel.variant.isOutgoing
        contentViewTopConstraint.constant = (cellViewModel.senderName == nil ? 0 : VisibleMessageCell.authorLabelBottomSpacing)
        contentViewTrailingConstraint1.isActive = cellViewModel.variant.isOutgoing
        contentViewTrailingConstraint2.isActive = cellViewModel.variant.isIncoming
        
        let bubbleBackgroundColor: ThemeValue = (cellViewModel.variant.isIncoming ? .messageBubble_incomingBackground : .messageBubble_outgoingBackground)
        bubbleView.themeBackgroundColor = bubbleBackgroundColor
        bubbleBackgroundView.themeBackgroundColor = bubbleBackgroundColor
        updateBubbleViewCorners()
        
        // Content view
        populateContentView(
            for: cellViewModel,
            playbackInfo: playbackInfo,
            shouldExpanded: shouldExpanded,
            lastSearchText: lastSearchText,
            using: dependencies
        )
        
        bubbleView.accessibilityIdentifier = "Message body"
        bubbleView.accessibilityLabel = bodyTappableLabel?.attributedText?.string
        bubbleView.isAccessibilityElement = true
        
        // Author label
        authorLabelTopConstraint.constant = (shouldAddTopInset ? Values.mediumSpacing : 0)
        authorLabel.isHidden = (cellViewModel.senderName == nil)
        authorLabel.text = cellViewModel.senderName
        authorLabel.themeTextColor = .textPrimary
        
        let authorLabelAvailableWidth: CGFloat = (VisibleMessageCell.getMaxWidth(for: cellViewModel) - 2 * VisibleMessageCell.authorLabelInset)
        let authorLabelAvailableSpace = CGSize(width: authorLabelAvailableWidth, height: .greatestFiniteMagnitude)
        let authorLabelSize = authorLabel.sizeThatFits(authorLabelAvailableSpace)
        authorLabelHeightConstraint.constant = (cellViewModel.senderName != nil ? authorLabelSize.height : 0)
        
        // Flip horizontally for RTL languages
        replyIconImageView.transform = CGAffineTransform.identity
            .scaledBy(
                x: (Dependencies.isRTL ? -1 : 1),
                y: 1
            )

        // Swipe to reply
        if ContextMenuVC.viewModelCanReply(cellViewModel, using: dependencies) {
            addGestureRecognizer(panGestureRecognizer)
        }
        else {
            removeGestureRecognizer(panGestureRecognizer)
        }
        
        // Under bubble content
        underBubbleStackView.alignment = (cellViewModel.variant.isOutgoing ?.trailing : .leading)
        underBubbleStackViewIncomingLeadingConstraint.isActive = !cellViewModel.variant.isOutgoing
        underBubbleStackViewIncomingTrailingConstraint.isActive = !cellViewModel.variant.isOutgoing
        underBubbleStackViewOutgoingLeadingConstraint.isActive = cellViewModel.variant.isOutgoing
        underBubbleStackViewOutgoingTrailingConstraint.isActive = cellViewModel.variant.isOutgoing
        
        // Reaction view
        reactionContainerView.isHidden = (cellViewModel.reactionInfo?.isEmpty != false)
        populateReaction(
            for: cellViewModel,
            maxWidth: VisibleMessageCell.getMaxWidth(
                for: cellViewModel,
                includingOppositeGutter: false
            ),
            showExpandedReactions: showExpandedReactions
        )
        
        // Message status image view
        let (image, statusText, tintColor) = cellViewModel.state.statusIconInfo(
            variant: cellViewModel.variant,
            hasBeenReadByRecipient: cellViewModel.hasBeenReadByRecipient,
            hasAttachments: (cellViewModel.attachments?.isEmpty == false)
        )
        messageStatusLabel.text = statusText
        messageStatusLabel.themeTextColor = tintColor
        messageStatusImageView.image = image
        messageStatusLabel.accessibilityIdentifier = "Message sent status: \(statusText ?? "invalid")"
        messageStatusImageView.themeTintColor = tintColor
        messageStatusContainerView.isHidden = (
            (cellViewModel.expiresInSeconds ?? 0) == 0 && (
                !cellViewModel.variant.isOutgoing ||
                cellViewModel.variant.isDeletedMessage ||
                cellViewModel.variant == .infoCall ||
                (
                    cellViewModel.state == .sent &&
                    !cellViewModel.isLastOutgoing
                )
            )
        )
        messageStatusLabelPaddingView.isHidden = (
            messageStatusContainerView.isHidden ||
            cellViewModel.isLast
        )
        
        // Timer
        if
            let expiresStartedAtMs: Double = cellViewModel.expiresStartedAtMs,
            let expiresInSeconds: TimeInterval = cellViewModel.expiresInSeconds
        {
            let expirationTimestampMs: Double = (expiresStartedAtMs + (expiresInSeconds * 1000))
            
            timerView.configure(
                expirationTimestampMs: expirationTimestampMs,
                initialDurationSeconds: expiresInSeconds,
                using: dependencies
            )
            timerView.themeTintColor = tintColor
            timerView.isHidden = false
            messageStatusImageView.isHidden = true
        }
        else {
            timerView.isHidden = true
            messageStatusImageView.isHidden = false
        }
        
        timerViewOutgoingMessageConstraint.isActive = cellViewModel.variant.isOutgoing
        timerViewIncomingMessageConstraint.isActive = cellViewModel.variant.isIncoming
        messageStatusLabelOutgoingMessageConstraint.isActive = cellViewModel.variant.isOutgoing
        messageStatusLabelIncomingMessageConstraint.isActive = cellViewModel.variant.isIncoming
        
        // Set the height of the underBubbleStackView to 0 if it has no content (need to do this
        // otherwise it can randomly stretch)
        underBubbleStackViewNoHeightConstraint.isActive = underBubbleStackView.arrangedSubviews
            .filter { !$0.isHidden }
            .isEmpty
    }

    private func populateContentView(
        for cellViewModel: MessageViewModel,
        playbackInfo: ConversationViewModel.PlaybackInfo?,
        shouldExpanded: Bool,
        lastSearchText: String?,
        using dependencies: Dependencies
    ) {
        let bodyLabelTextColor: ThemeValue = (cellViewModel.variant.isOutgoing ?
            .messageBubble_outgoingText :
            .messageBubble_incomingText
        )
        snContentView.alignment = (cellViewModel.variant.isOutgoing ? .trailing : .leading)
        
        for subview in snContentView.arrangedSubviews {
            snContentView.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
        for subview in bubbleView.subviews {
            subview.removeFromSuperview()
        }
        albumView = nil
        quoteView = nil
        linkPreviewView = nil
        documentView = nil
        bodyTappableLabel = nil
        
        /// These variants have no content so do nothing after cleaning up old state
        guard
            cellViewModel.cellType != .typingIndicator &&
            cellViewModel.cellType != .dateHeader &&
            cellViewModel.cellType != .unreadMarker
        else { return }
        
        /// Handle the deleted state first (it's much simpler than the others)
        guard !cellViewModel.variant.isDeletedMessage else {
            let inset: CGFloat = 12
            let deletedMessageView: DeletedMessageView = DeletedMessageView(
                textColor: bodyLabelTextColor,
                variant: cellViewModel.variant,
                maxWidth: (VisibleMessageCell.getMaxWidth(for: cellViewModel) - 2 * inset)
            )
            bubbleView.addSubview(deletedMessageView)
            deletedMessageView.pin(to: bubbleView)
            snContentView.addArrangedSubview(bubbleBackgroundView)
            return
        }
        
        /// The `textOnlyMessage` variant has a slightly different behaviour (as it's the only variant which supports link previews)
        /// so we handle that case first
        // FIXME: We should support rendering link previews alongside the other variants (bigger refactor)
        guard cellViewModel.cellType != .textOnlyMessage else {
            let inset: CGFloat = 12
            let maxWidth: CGFloat = (VisibleMessageCell.getMaxWidth(for: cellViewModel) - 2 * inset)
            
            if let linkPreview: LinkPreview = cellViewModel.linkPreview {
                switch linkPreview.variant {
                    case .standard:
                        let linkPreviewView: LinkPreviewView = LinkPreviewView(maxWidth: maxWidth)
                        linkPreviewView.update(
                            with: LinkPreview.SentState(
                                linkPreview: linkPreview,
                                imageAttachment: cellViewModel.linkPreviewAttachment,
                                using: dependencies
                            ),
                            isOutgoing: cellViewModel.variant.isOutgoing,
                            delegate: self,
                            cellViewModel: cellViewModel,
                            bodyLabelTextColor: bodyLabelTextColor,
                            lastSearchText: lastSearchText,
                            using: dependencies
                        )
                        self.linkPreviewView = linkPreviewView
                        bubbleView.addSubview(linkPreviewView)
                        linkPreviewView.pin(to: bubbleView, withInset: 0)
                        snContentView.addArrangedSubview(bubbleBackgroundView)
                        self.bodyTappableLabel = linkPreviewView.bodyTappableLabel
                        
                    case .openGroupInvitation:
                        let openGroupInvitationView: OpenGroupInvitationView = OpenGroupInvitationView(
                            name: (linkPreview.title ?? ""),
                            url: linkPreview.url,
                            textColor: bodyLabelTextColor,
                            isOutgoing: cellViewModel.variant.isOutgoing
                        )
                        openGroupInvitationView.isAccessibilityElement = true
                        openGroupInvitationView.accessibilityIdentifier = "Community invitation"
                        openGroupInvitationView.accessibilityLabel = cellViewModel.linkPreview?.title
                        bubbleView.addSubview(openGroupInvitationView)
                        bubbleView.pin(to: openGroupInvitationView)
                        snContentView.addArrangedSubview(bubbleBackgroundView)
                }
            }
            else {
                // Stack view
                let stackView = UIStackView(arrangedSubviews: [])
                stackView.axis = .vertical
                stackView.spacing = 2
                
                // Quote view
                if let quote: Quote = cellViewModel.quote {
                    let hInset: CGFloat = 2
                    let quoteView: QuoteView = QuoteView(
                        for: .regular,
                        authorId: quote.authorId,
                        quotedText: quote.body,
                        threadVariant: cellViewModel.threadVariant,
                        currentUserSessionIds: (cellViewModel.currentUserSessionIds ?? []),
                        direction: (cellViewModel.variant.isOutgoing ? .outgoing : .incoming),
                        attachment: cellViewModel.quoteAttachment,
                        using: dependencies
                    )
                    self.quoteView = quoteView
                    let quoteViewContainer = UIView(wrapping: quoteView, withInsets: UIEdgeInsets(top: 0, leading: hInset, bottom: 0, trailing: hInset))
                    stackView.addArrangedSubview(quoteViewContainer)
                }
                
                // Body text view
                let (bodyTappableLabel, height) = VisibleMessageCell.getBodyTappableLabel(
                    for: cellViewModel,
                    with: maxWidth,
                    textColor: bodyLabelTextColor,
                    searchText: lastSearchText,
                    delegate: self,
                    using: dependencies
                )
                self.bodyTappableLabel = bodyTappableLabel
                self.bodyTappableLabelHeight = height
                stackView.addArrangedSubview(bodyTappableLabel)
                readMoreButton.themeTextColor = bodyLabelTextColor
                let maxHeight: CGFloat = VisibleMessageCell.getMaxHeightAfterTruncation(for: cellViewModel)
                self.bodayTappableLabelHeightConstraint = bodyTappableLabel.set(
                    .height,
                    to: (shouldExpanded ? height : min(height, maxHeight))
                )
                if (height > maxHeight && !shouldExpanded) {
                    stackView.addArrangedSubview(readMoreButton)
                    readMoreButton.isHidden = false
                }
                
                // Constraints
                bubbleView.addSubview(stackView)
                stackView.pin(to: bubbleView, withInset: inset)
                stackView.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth).isActive = true
                self.bodyContainerStackView = stackView
                snContentView.addArrangedSubview(bubbleBackgroundView)
            }
            return
        }
        
        func addViewWrappingInBubbleIfNeeded(_ targetView: UIView) {
            switch snContentView.arrangedSubviews.count {
                case 0:
                    bubbleView.addSubview(targetView)
                    targetView.pin(to: bubbleView)
                    snContentView.addArrangedSubview(bubbleBackgroundView)

                default:
                    /// Since we already have content we need to wrap the `targetView` in it's own
                    /// `bubbleView` (as it's likely the existing content is quote content)
                    let extraBubbleView: UIView = UIView()
                    extraBubbleView.clipsToBounds = true
                    extraBubbleView.themeBackgroundColor = (cellViewModel.variant.isIncoming ?
                        .messageBubble_incomingBackground :
                        .messageBubble_outgoingBackground
                    )
                    extraBubbleView.layer.cornerRadius = VisibleMessageCell.largeCornerRadius
                    extraBubbleView.layer.maskedCorners = getCornerMask(from: .allCorners)
                    extraBubbleView.set(.width, greaterThanOrEqualTo: VisibleMessageCell.largeCornerRadius * 2)
                    
                    extraBubbleView.addSubview(targetView)
                    targetView.pin(to: extraBubbleView)
                    snContentView.addArrangedSubview(extraBubbleView)
            }
        }
        
        /// Add any quote & body if present
        let inset: CGFloat = 12
        let maxWidth: CGFloat = (VisibleMessageCell.getMaxWidth(for: cellViewModel) - 2 * inset)
        
        switch (cellViewModel.quote, cellViewModel.body) {
            /// Both quote and body
            case (.some(let quote), .some(let body)) where !body.isEmpty:
                // Stack view
                let stackView = UIStackView(arrangedSubviews: [])
                stackView.axis = .vertical
                stackView.spacing = 2
                
                // Quote view
                let hInset: CGFloat = 2
                let quoteView: QuoteView = QuoteView(
                    for: .regular,
                    authorId: quote.authorId,
                    quotedText: quote.body,
                    threadVariant: cellViewModel.threadVariant,
                    currentUserSessionIds: (cellViewModel.currentUserSessionIds ?? []),
                    direction: (cellViewModel.variant.isOutgoing ? .outgoing : .incoming),
                    attachment: cellViewModel.quoteAttachment,
                    using: dependencies
                )
                self.quoteView = quoteView
                let quoteViewContainer = UIView(wrapping: quoteView, withInsets: UIEdgeInsets(top: 0, leading: hInset, bottom: 0, trailing: hInset))
                stackView.addArrangedSubview(quoteViewContainer)
                
                // Body
                let (bodyTappableLabel, height) = VisibleMessageCell.getBodyTappableLabel(
                    for: cellViewModel,
                    with: maxWidth,
                    textColor: bodyLabelTextColor,
                    searchText: lastSearchText,
                    delegate: self,
                    using: dependencies
                )
                self.bodyTappableLabel = bodyTappableLabel
                self.bodyTappableLabelHeight = height
                stackView.addArrangedSubview(bodyTappableLabel)
                readMoreButton.themeTextColor = bodyLabelTextColor
                let maxHeight: CGFloat = VisibleMessageCell.getMaxHeightAfterTruncation(for: cellViewModel)
                self.bodayTappableLabelHeightConstraint = bodyTappableLabel.set(
                    .height,
                    to: (shouldExpanded ? height : min(height, maxHeight))
                )
                if (height > maxHeight && !shouldExpanded) {
                    stackView.addArrangedSubview(readMoreButton)
                    readMoreButton.isHidden = false
                }
                
                // Constraints
                bubbleView.addSubview(stackView)
                stackView.pin(to: bubbleView, withInset: inset)
                stackView.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth).isActive = true
                self.bodyContainerStackView = stackView
                snContentView.addArrangedSubview(bubbleBackgroundView)
                
            /// Just body
            case (_, .some(let body)) where !body.isEmpty:
                // Stack view
                let stackView = UIStackView(arrangedSubviews: [])
                stackView.axis = .vertical
                stackView.spacing = 2
            
                let (bodyTappableLabel, height) = VisibleMessageCell.getBodyTappableLabel(
                    for: cellViewModel,
                    with: maxWidth,
                    textColor: bodyLabelTextColor,
                    searchText: lastSearchText,
                    delegate: self,
                    using: dependencies
                )

                self.bodyTappableLabel = bodyTappableLabel
                self.bodyTappableLabelHeight = height
                stackView.addArrangedSubview(bodyTappableLabel)
                readMoreButton.themeTextColor = bodyLabelTextColor
                let maxHeight: CGFloat = VisibleMessageCell.getMaxHeightAfterTruncation(for: cellViewModel)
                self.bodayTappableLabelHeightConstraint = bodyTappableLabel.set(
                    .height,
                    to: (shouldExpanded ? height : min(height, maxHeight))
                )
                if (height > maxHeight && !shouldExpanded) {
                    stackView.addArrangedSubview(readMoreButton)
                    readMoreButton.isHidden = false
                }
                
                // Constraints
                bubbleView.addSubview(stackView)
                stackView.pin(to: bubbleView, withInset: inset)
                stackView.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth).isActive = true
                self.bodyContainerStackView = stackView
                snContentView.addArrangedSubview(bubbleBackgroundView)
            
            /// Just quote
            case (.some(let quote), _):
                let quoteView: QuoteView = QuoteView(
                    for: .regular,
                    authorId: quote.authorId,
                    quotedText: quote.body,
                    threadVariant: cellViewModel.threadVariant,
                    currentUserSessionIds: (cellViewModel.currentUserSessionIds ?? []),
                    direction: (cellViewModel.variant.isOutgoing ? .outgoing : .incoming),
                    attachment: cellViewModel.quoteAttachment,
                    using: dependencies
                )
                self.quoteView = quoteView

                bubbleView.addSubview(quoteView)
                quoteView.pin(to: bubbleView, withInset: inset)
                snContentView.addArrangedSubview(bubbleBackgroundView)
            
            /// Neither quote or body
            default: break
        }
        
        /// If it's an incoming media message and the thread isn't trusted then show the placeholder view
        if cellViewModel.variant == .standardIncoming && !cellViewModel.threadIsTrusted {
            let mediaPlaceholderView = MediaPlaceholderView(cellViewModel: cellViewModel, textColor: bodyLabelTextColor)
            addViewWrappingInBubbleIfNeeded(mediaPlaceholderView)
            return
        }

        switch cellViewModel.cellType {
            case .typingIndicator, .dateHeader, .unreadMarker, .textOnlyMessage: break

            case .mediaMessage:
                // Album view
                let maxMessageWidth: CGFloat = VisibleMessageCell.getMaxWidth(for: cellViewModel)
                let albumView = MediaAlbumView(
                    items: (cellViewModel.attachments?
                        .filter { $0.isVisualMedia })
                        .defaulting(to: []),
                    isOutgoing: cellViewModel.variant.isOutgoing,
                    maxMessageWidth: maxMessageWidth,
                    using: dependencies
                )
                self.albumView = albumView
                let size = getSize(for: cellViewModel)
                albumView.set(.width, to: size.width)
                albumView.set(.height, to: size.height)
                albumView.accessibilityLabel = "contentDescriptionMediaMessage".localized()
                snContentView.addArrangedSubview(albumView)
            
            case .voiceMessage:
                guard let attachment: Attachment = cellViewModel.attachments?.first(where: { $0.isAudio }) else {
                    return
                }
                
                let voiceMessageView: VoiceMessageView = VoiceMessageView()
                voiceMessageView.update(
                    with: attachment,
                    isPlaying: (playbackInfo?.state == .playing),
                    progress: (playbackInfo?.progress ?? 0),
                    playbackRate: (playbackInfo?.playbackRate ?? 1),
                    oldPlaybackRate: (playbackInfo?.oldPlaybackRate ?? 1)
                )
                self.voiceMessageView = voiceMessageView
                addViewWrappingInBubbleIfNeeded(voiceMessageView)
                
            case .audio, .genericAttachment:
                guard let attachment: Attachment = cellViewModel.attachments?.first else { preconditionFailure() }
                
                // Document view
                let documentView = DocumentView(attachment: attachment, textColor: bodyLabelTextColor)
                self.documentView = documentView
                addViewWrappingInBubbleIfNeeded(documentView)
        }
    }
    
    private func populateReaction(
        for cellViewModel: MessageViewModel,
        maxWidth: CGFloat,
        showExpandedReactions: Bool
    ) {
        let reactions: OrderedDictionary<EmojiWithSkinTones, ReactionViewModel> = (cellViewModel.reactionInfo ?? [])
            .reduce(into: OrderedDictionary()) { result, reactionInfo in
                guard let emoji: EmojiWithSkinTones = EmojiWithSkinTones(rawValue: reactionInfo.reaction.emoji) else {
                    return
                }
                
                let isSelfSend: Bool = (cellViewModel.currentUserSessionIds ?? []).contains(reactionInfo.reaction.authorId)
                
                if let value: ReactionViewModel = result.value(forKey: emoji) {
                    result.replace(
                        key: emoji,
                        value: ReactionViewModel(
                            emoji: emoji,
                            number: (value.number + Int(reactionInfo.reaction.count)),
                            showBorder: (value.showBorder || isSelfSend)
                        )
                    )
                }
                else {
                    result.append(
                        key: emoji,
                        value: ReactionViewModel(
                            emoji: emoji,
                            number: Int(reactionInfo.reaction.count),
                            showBorder: isSelfSend
                        )
                    )
                }
            }
        
        reactionContainerView.update(
            reactions.orderedValues,
            maxWidth: maxWidth,
            showingAllReactions: showExpandedReactions,
            showNumbers: (
                cellViewModel.threadVariant == .legacyGroup ||
                cellViewModel.threadVariant == .group ||
                cellViewModel.threadVariant == .community
            )
        )
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        updateBubbleViewCorners()
    }

    private func updateBubbleViewCorners() {
        let cornersToRound: UIRectCorner = .allCorners
        
        bubbleBackgroundView.layer.cornerRadius = VisibleMessageCell.largeCornerRadius
        bubbleBackgroundView.layer.maskedCorners = getCornerMask(from: cornersToRound)
        bubbleView.layer.cornerRadius = VisibleMessageCell.largeCornerRadius
        bubbleView.layer.maskedCorners = getCornerMask(from: cornersToRound)
    }
    
    override func dynamicUpdate(with cellViewModel: MessageViewModel, playbackInfo: ConversationViewModel.PlaybackInfo?) {
        guard !cellViewModel.variant.isDeletedMessage else { return }
        
        // If it's an incoming media message and the thread isn't trusted then show the placeholder view
        if cellViewModel.cellType != .textOnlyMessage && cellViewModel.variant == .standardIncoming && !cellViewModel.threadIsTrusted {
            return
        }

        switch cellViewModel.cellType {
            case .voiceMessage:
                guard let attachment: Attachment = cellViewModel.attachments?.first(where: { $0.isAudio }) else {
                    return
                }
                
                self.voiceMessageView?.update(
                    with: attachment,
                    isPlaying: (playbackInfo?.state == .playing),
                    progress: (playbackInfo?.progress ?? 0),
                    playbackRate: (playbackInfo?.playbackRate ?? 1),
                    oldPlaybackRate: (playbackInfo?.oldPlaybackRate ?? 1)
                )
                
            default: break
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        
        for subview in snContentView.arrangedSubviews {
            snContentView.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
        for subview in bubbleView.subviews {
            subview.removeFromSuperview()
        }
        albumView = nil
        quoteView = nil
        linkPreviewView = nil
        documentView = nil
        bodyTappableLabel = nil
        bodyTappableLabelHeight = 0
        bodayTappableLabelHeightConstraint = nil
        viewsToMoveForReply.forEach { $0.transform = .identity }
        replyButton.alpha = 0
        timerView.prepareForReuse()
    }

    // MARK: - Interaction

    override func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true // Needed for the pan gesture recognizer to work with the table view's pan gesture recognizer
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer == panGestureRecognizer {
            let v = panGestureRecognizer.velocity(in: self)
            // Only allow swipes to the left; allowing swipes to the right gets in the way of
            // the default iOS swipe to go back gesture
            guard
                (Dependencies.isRTL && v.x > 0) ||
                (!Dependencies.isRTL && v.x < 0)
            else { return false }
            
            return abs(v.x) > abs(v.y) // It has to be more horizontal than vertical
        }
        
        return true
    }

    func highlight() {
        let shadowColor: ThemeValue = (ThemeManager.currentTheme.interfaceStyle == .light ?
            .black :
            .primary
        )
        let opacity: Float = (ThemeManager.currentTheme.interfaceStyle == .light ?
            0.5 :
            1
        )
        
        DispatchQueue.main.async { [weak self] in
            let oldMasksToBounds: Bool = (self?.layer.masksToBounds ?? false)
            self?.layer.masksToBounds = false
            self?.bubbleBackgroundView.setShadow(radius: 10, opacity: opacity, offset: .zero, color: shadowColor)
            
            UIView.animate(
                withDuration: 1.6,
                delay: 0,
                options: .curveEaseInOut,
                animations: {
                    self?.bubbleBackgroundView.setShadow(radius: 0, opacity: 0, offset: .zero, color: .clear)
                },
                completion: { _ in
                    self?.layer.masksToBounds = oldMasksToBounds
                }
            )
        }
    }
    
    @objc func handleLongPress(_ gestureRecognizer: UITapGestureRecognizer) {
        if [ .ended, .cancelled, .failed ].contains(gestureRecognizer.state) {
            isHandlingLongPress = false
            return
        }
        guard !isHandlingLongPress, let cellViewModel: MessageViewModel = self.viewModel else { return }
        
        let location = gestureRecognizer.location(in: self)
        
        if reactionContainerView.bounds.contains(reactionContainerView.convert(location, from: self)) {
            let convertedLocation = reactionContainerView.convert(location, from: self)
            
            for reactionView in reactionContainerView.reactionViews {
                if reactionContainerView.convert(reactionView.frame, from: reactionView.superview).contains(convertedLocation) {
                    delegate?.showReactionList(cellViewModel, selectedReaction: reactionView.viewModel.emoji)
                    break
                }
            }
        }
        else {
            delegate?.handleItemLongPressed(cellViewModel)
        }
        
        isHandlingLongPress = true
    }

    @objc private func handleTap(_ gestureRecognizer: UITapGestureRecognizer) {
        guard let cellViewModel: MessageViewModel = self.viewModel else { return }
        
        let location = gestureRecognizer.location(in: self)
        
        if profilePictureView.bounds.contains(profilePictureView.convert(location, from: self)), cellViewModel.shouldShowProfile {
            // For open groups only attempt to start a conversation if the author has a blinded id
            guard cellViewModel.threadVariant != .community else {
                // FIXME: Add in support for opening a conversation with a 'blinded25' id
                guard (try? SessionId.Prefix(from: cellViewModel.authorId)) == .blinded15 else { return }
                
                delegate?.startThread(
                    with: cellViewModel.authorId,
                    openGroupServer: cellViewModel.threadOpenGroupServer,
                    openGroupPublicKey: cellViewModel.threadOpenGroupPublicKey
                )
                return
            }
            
            delegate?.startThread(
                with: cellViewModel.authorId,
                openGroupServer: nil,
                openGroupPublicKey: nil
            )
        }
        else if replyButton.alpha > 0 && replyButton.bounds.contains(replyButton.convert(location, from: self)) {
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            reply()
        }
        else if reactionContainerView.bounds.contains(reactionContainerView.convert(location, from: self)) {
            let convertedLocation = reactionContainerView.convert(location, from: self)
            
            for reactionView in reactionContainerView.reactionViews {
                if reactionContainerView.convert(reactionView.frame, from: reactionView.superview).contains(convertedLocation) {
                    
                    if reactionView.viewModel.showBorder {
                        delegate?.removeReact(cellViewModel, for: reactionView.viewModel.emoji)
                    }
                    else {
                        delegate?.react(cellViewModel, with: reactionView.viewModel.emoji)
                    }
                    return
                }
            }
            
            if let expandButton = reactionContainerView.expandButton, expandButton.bounds.contains(expandButton.convert(location, from: self)) {
                reactionContainerView.showAllEmojis()
                delegate?.needsLayout(for: cellViewModel, expandingReactions: true)
            }
            
            if reactionContainerView.collapseButton.frame.contains(convertedLocation) {
                reactionContainerView.showLessEmojis()
                delegate?.needsLayout(for: cellViewModel, expandingReactions: false)
            }
        }
        else if snContentView.bounds.contains(snContentView.convert(location, from: self)) {
            if !readMoreButton.isHidden && readMoreButton.bounds.contains(readMoreButton.convert(location, from: self)) {
                bodayTappableLabelHeightConstraint?.constant = self.bodyTappableLabelHeight
                bodyTappableLabel?.invalidateIntrinsicContentSize()
                readMoreButton.isHidden = true
                self.bodyContainerStackView?.removeArrangedSubview(readMoreButton)
                delegate?.handleReadMoreButtonTapped(self, for: cellViewModel)
            } else {
                delegate?.handleItemTapped(cellViewModel, cell: self, cellLocation: location)
            }
        }
    }

    @objc private func handleDoubleTap() {
        guard let cellViewModel: MessageViewModel = self.viewModel else { return }
        
        delegate?.handleItemDoubleTapped(cellViewModel)
    }

    @objc private func handlePan(_ gestureRecognizer: UIPanGestureRecognizer) {
        guard let cellViewModel: MessageViewModel = self.viewModel else { return }
        
        let translationX = gestureRecognizer
            .translation(in: self)
            .x
            .clamp(
                (Dependencies.isRTL ? 0 : -CGFloat.greatestFiniteMagnitude),
                (Dependencies.isRTL ? CGFloat.greatestFiniteMagnitude : 0)
            )
        
        switch gestureRecognizer.state {
            case .began: delegate?.handleItemSwiped(cellViewModel, state: .began)
                
            case .changed:
                // The idea here is to asymptotically approach a maximum drag distance
                let damping: CGFloat = 20
                let sign: CGFloat = (Dependencies.isRTL ? 1 : -1)
                let x = (damping * (sqrt(abs(translationX)) / sqrt(damping))) * sign
                viewsToMoveForReply.forEach { $0.transform = CGAffineTransform(translationX: x, y: 0) }
                
                if timerView.isHidden {
                    replyButton.alpha = abs(translationX) / VisibleMessageCell.maxBubbleTranslationX
                }
                else {
                    replyButton.alpha = 0 // Always hide the reply button if the timer view is showing, otherwise they can overlap
                }
                
                if abs(translationX) > VisibleMessageCell.swipeToReplyThreshold && abs(previousX) < VisibleMessageCell.swipeToReplyThreshold {
                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred() // Let the user know when they've hit the swipe to reply threshold
                }
                previousX = translationX
                
            case .ended, .cancelled:
                if abs(translationX) > VisibleMessageCell.swipeToReplyThreshold {
                    delegate?.handleItemSwiped(cellViewModel, state: .ended)
                    reply()
                }
                else {
                    delegate?.handleItemSwiped(cellViewModel, state: .cancelled)
                    resetReply()
                }
                
            default: break
        }
    }
    
    func tapableLabel(_ label: TappableLabel, didTapUrl url: String, atRange range: NSRange) {
        delegate?.openUrl(url)
    }
    
    private func resetReply() {
        UIView.animate(withDuration: 0.25) { [weak self] in
            self?.viewsToMoveForReply.forEach { $0.transform = .identity }
            self?.replyButton.alpha = 0
        }
    }

    private func reply() {
        guard let cellViewModel: MessageViewModel = self.viewModel else { return }
        
        resetReply()
        delegate?.handleReplyButtonTapped(for: cellViewModel)
    }

    // MARK: - Convenience
    
    private func getCornerMask(from rectCorner: UIRectCorner) -> CACornerMask {
        guard !rectCorner.contains(.allCorners) else {
            return [ .layerMaxXMinYCorner, .layerMinXMinYCorner, .layerMaxXMaxYCorner, .layerMinXMaxYCorner]
        }
        
        var cornerMask = CACornerMask()
        if rectCorner.contains(.topRight) { cornerMask.insert(.layerMaxXMinYCorner) }
        if rectCorner.contains(.topLeft) { cornerMask.insert(.layerMinXMinYCorner) }
        if rectCorner.contains(.bottomRight) { cornerMask.insert(.layerMaxXMaxYCorner) }
        if rectCorner.contains(.bottomLeft) { cornerMask.insert(.layerMinXMaxYCorner) }
        return cornerMask
    }

    private static func getFontSize(for cellViewModel: MessageViewModel) -> CGFloat {
        let baselineFontSize = Values.mediumFontSize
        
        guard cellViewModel.containsOnlyEmoji == true else { return baselineFontSize }
        
        switch (cellViewModel.glyphCount ?? 0) {
            case 1: return baselineFontSize + 30
            case 2: return baselineFontSize + 24
            case 3, 4, 5: return baselineFontSize + 18
            default: return baselineFontSize
        }
    }
    
    private static func getMaxHeightAfterTruncation(for cellViewModel: MessageViewModel) -> CGFloat {
        return CGFloat(maxNumberOfLinesAfterTruncation) * UIFont.systemFont(ofSize: getFontSize(for: cellViewModel)).lineHeight
    }

    private func getSize(for cellViewModel: MessageViewModel) -> CGSize {
        guard let mediaAttachments: [Attachment] = cellViewModel.attachments?.filter({ $0.isVisualMedia }) else {
            preconditionFailure()
        }
        
        let maxMessageWidth = VisibleMessageCell.getMaxWidth(for: cellViewModel)
        let defaultSize = MediaAlbumView.layoutSize(forMaxMessageWidth: maxMessageWidth, items: mediaAttachments)
        
        guard
            let firstAttachment: Attachment = mediaAttachments.first,
            var width: CGFloat = firstAttachment.width.map({ CGFloat($0) }),
            var height: CGFloat = firstAttachment.height.map({ CGFloat($0) }),
            mediaAttachments.count == 1,
            width > 0,
            height > 0
        else { return defaultSize }
        
        // Honor the content aspect ratio for single media
        let size: CGSize = CGSize(width: width, height: height)
        var aspectRatio = (size.width / size.height)
        // Clamp the aspect ratio so that very thin/wide content still looks alright
        let minAspectRatio: CGFloat = 0.35
        let maxAspectRatio = 1 / minAspectRatio
        let maxSize = CGSize(width: maxMessageWidth, height: maxMessageWidth)
        aspectRatio = aspectRatio.clamp(minAspectRatio, maxAspectRatio)
        
        if aspectRatio > 1 {
            width = maxSize.width
            height = width / aspectRatio
        }
        else {
            height = maxSize.height
            width = height * aspectRatio
        }
        
        // Don't blow up small images unnecessarily
        let minSize: CGFloat = 150
        let shortSourceDimension = min(size.width, size.height)
        let shortDestinationDimension = min(width, height)
        
        if shortDestinationDimension > minSize && shortDestinationDimension > shortSourceDimension {
            let factor = minSize / shortDestinationDimension
            width *= factor; height *= factor
        }
        
        return CGSize(width: width, height: height)
    }

    static func getMaxWidth(for cellViewModel: MessageViewModel, includingOppositeGutter: Bool = true) -> CGFloat {
        let screen: CGRect = UIScreen.main.bounds
        let width: CGFloat = UIDevice.current.isIPad ? screen.width * 0.75 : screen.width
        let oppositeEdgePadding: CGFloat = (includingOppositeGutter ? gutterSize : contactThreadHSpacing)
        
        switch cellViewModel.variant {
            case .standardOutgoing, .standardOutgoingDeleted, .standardOutgoingDeletedLocally:
                return (width - contactThreadHSpacing - oppositeEdgePadding)
                
            case .standardIncoming, .standardIncomingDeleted, .standardIncomingDeletedLocally:
                let isGroupThread = (
                    cellViewModel.threadVariant == .community ||
                    cellViewModel.threadVariant == .legacyGroup ||
                    cellViewModel.threadVariant == .group
                )
                let leftEdgeGutterSize = (isGroupThread ? leftGutterSize : contactThreadHSpacing)
                
                return (width - leftEdgeGutterSize - oppositeEdgePadding)
                
            default: preconditionFailure()
        }
    }
    
    // stringlint:ignore_contents
    static func getBodyAttributedText(
        for cellViewModel: MessageViewModel,
        textColor: ThemeValue,
        searchText: String?,
        using dependencies: Dependencies
    ) -> ThemedAttributedString? {
        guard
            let body: String = cellViewModel.body,
            !body.isEmpty
        else { return nil }
        
        let isOutgoing: Bool = (cellViewModel.variant == .standardOutgoing)
        let attributedText: ThemedAttributedString = MentionUtilities.highlightMentions(
            in: body,
            threadVariant: cellViewModel.threadVariant,
            currentUserSessionIds: (cellViewModel.currentUserSessionIds ?? []),
            location: (isOutgoing ? .outgoingMessage : .incomingMessage),
            textColor: textColor,
            attributes: [
                .themeForegroundColor: textColor,
                .font: UIFont.systemFont(ofSize: getFontSize(for: cellViewModel))
            ],
            using: dependencies
        )
        
        // Custom handle links
        let links: [URL: NSRange] = {
            guard let detector: NSDataDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
                return [:]
            }
            
            // Note: The 'String.count' value is based on actual character counts whereas
            // NSAttributedString and NSRange are both based on UTF-16 encoded lengths, so
            // in order to avoid strings which contain emojis breaking strings which end
            // with URLs we need to use the 'String.utf16.count' value when creating the range
            return detector
                .matches(
                    in: attributedText.string,
                    options: [],
                    range: NSRange(location: 0, length: attributedText.string.utf16.count)
                )
                .reduce(into: [:]) { result, match in
                    guard
                        let matchUrl: URL = match.url,
                        let originalRange: Range = Range(match.range, in: attributedText.string)
                    else { return }
                    
                    /// If the URL entered didn't have a scheme it will default to 'http', we want to catch this and
                    /// set the scheme to 'https' instead as we don't load previews for 'http' so this will result
                    /// in more previews actually getting loaded without forcing the user to enter 'https://' before
                    /// every URL they enter
                    let originalString: String = String(attributedText.string[originalRange])
                    
                    guard matchUrl.absoluteString != "http://\(originalString)" else {
                        guard let httpsUrl: URL = URL(string: "https://\(originalString)") else {
                            return
                        }
                        
                        result[httpsUrl] = match.range
                        return
                    }
                    
                    result[matchUrl] = match.range
                }
        }()
        
        for (linkUrl, urlRange) in links {
            attributedText.addAttributes(
                [
                    .font: UIFont.systemFont(ofSize: getFontSize(for: cellViewModel)),
                    .themeForegroundColor: textColor,
                    .themeUnderlineColor: textColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .attachment: linkUrl
                ],
                range: urlRange
            )
        }
        
        // If there is a valid search term then highlight each part that matched
        if let searchText = searchText, searchText.count >= ConversationSearchController.minimumSearchTextLength {
            let normalizedBody: String = attributedText.string.lowercased()
            
            SessionThreadViewModel.searchTermParts(searchText)
                .map { part -> String in
                    guard part.hasPrefix("\"") && part.hasSuffix("\"") else { return part }
                    
                    let partRange = (part.index(after: part.startIndex)..<part.index(before: part.endIndex))
                    return String(part[partRange])
                }
                .forEach { part in
                    // Highlight all ranges of the text (Note: The search logic only finds
                    // results that start with the term so we use the regex below to ensure
                    // we only highlight those cases)
                    normalizedBody
                        .ranges(
                            of: (Dependencies.isRTL ?
                                 "(\(part.lowercased()))(^|[^a-zA-Z0-9])" :
                                 "(^|[^a-zA-Z0-9])(\(part.lowercased()))"
                            ),
                            options: [.regularExpression]
                        )
                        .forEach { range in
                            let targetRange: Range<String.Index> = {
                                let term: String = String(normalizedBody[range])
                                
                                // If the matched term doesn't actually match the "part" value then it means
                                // we've matched a term after a non-alphanumeric character so need to shift
                                // the range over by 1
                                guard term.starts(with: part.lowercased()) else {
                                    return (normalizedBody.index(after: range.lowerBound)..<range.upperBound)
                                }
                                
                                return range
                            }()
                            
                            let legacyRange: NSRange = NSRange(targetRange, in: normalizedBody)
                            attributedText.addAttribute(.themeBackgroundColor, value: ThemeValue.backgroundPrimary, range: legacyRange)
                            attributedText.addAttribute(.themeForegroundColor, value: ThemeValue.textPrimary, range: legacyRange)
                        }
                }
        }
        
        return attributedText
    }
    
    static func getBodyTappableLabel(
        for cellViewModel: MessageViewModel,
        with availableWidth: CGFloat,
        textColor: ThemeValue,
        searchText: String?,
        delegate: TappableLabelDelegate?,
        using dependencies: Dependencies
    ) -> (label: TappableLabel, height: CGFloat) {
        let result: TappableLabel = TappableLabel()
        result.setContentCompressionResistancePriority(.required, for: .vertical)
        result.themeAttributedText = VisibleMessageCell.getBodyAttributedText(
            for: cellViewModel,
            textColor: textColor,
            searchText: searchText,
            using: dependencies
        )
        result.themeBackgroundColor = .clear
        result.isOpaque = false
        result.isUserInteractionEnabled = true
        result.delegate = delegate
        
        let availableSpace: CGSize = CGSize(width: availableWidth, height: .greatestFiniteMagnitude)
        let size: CGSize = result.sizeThatFits(availableSpace)

        return (result, size.height)
    }
}
