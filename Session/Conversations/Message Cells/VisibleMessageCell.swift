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
    
    override var allowedGestureRecognizers: Set<GestureRecognizerType> {
        return [
            .tap,
            .longPress,
            .doubleTap
        ]
    }
    
    private lazy var panGestureRecognizer: UIPanGestureRecognizer = {
        let result = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        result.delegate = self
        return result
    }()
    
    // MARK: - UI Components
    
    private lazy var contentHStackTopConstraint: NSLayoutConstraint =
        contentHStack.pin(.top, to: .top, of: contentView)
    
    private lazy var viewsToMoveForReply: [UIView] = [
        snContentView,
        profilePictureView,
        replyButton,
        timerView,
        messageStatusStackView,
        reactionContainerView
    ]
    
    private lazy var leadingSpacer: UIView = {
        let result: UIView = UIView()
        result.setContentHugging(.horizontal, to: .defaultLow)
        result.setCompressionResistance(.horizontal, to: .defaultLow)
        
        return result
    }()
    
    private lazy var trailingSpacer: UIView = {
        let result: UIView = UIView()
        result.setContentHugging(.horizontal, to: .defaultLow)
        result.setCompressionResistance(.horizontal, to: .defaultLow)
        
        return result
    }()
    
    private lazy var profilePictureViewContainer: UIView = {
        let result: UIView = UIView()
        
        return result
    }()
    
    private lazy var profilePictureView: ProfilePictureView = ProfilePictureView(
        size: .message,
        dataManager: nil
    )
    
    public lazy var contentHStack: UIStackView = {
        let result: UIStackView = UIStackView(
            arrangedSubviews: [leadingSpacer, profilePictureViewContainer, mainVStack, trailingSpacer]
        )
        result.axis = .horizontal
        result.alignment = .fill
        result.spacing = VisibleMessageCell.groupThreadHSpacing
        
        return result
    }()
    
    lazy var bubbleBackgroundView: UIView = {
        let result = UIView()
        result.layer.cornerRadius = VisibleMessageCell.largeCornerRadius
        result.setContentHugging(.vertical, to: .required)
        result.setCompressionResistance(.vertical, to: .required)
        
        return result
    }()

    lazy var bubbleView: UIView = {
        let result = UIView()
        result.clipsToBounds = true
        result.layer.cornerRadius = VisibleMessageCell.largeCornerRadius
        result.set(.width, greaterThanOrEqualTo: VisibleMessageCell.largeCornerRadius * 2)
        result.setContentHugging(.vertical, to: .required)
        result.setCompressionResistance(.vertical, to: .required)
        
        return result
    }()
    
    private lazy var mainVStack: UIStackView = {
        let result: UIStackView = UIStackView(
            arrangedSubviews: [authorLabel, snContentView, underBubbleStackView]
        )
        result.axis = .vertical
        result.alignment = .fill
        result.setCustomSpacing(VisibleMessageCell.authorLabelBottomSpacing, after: authorLabel)
        result.setCustomSpacing(Values.verySmallSpacing, after: snContentView)
        result.setContentHugging(.vertical, to: .required)
        result.setCompressionResistance(.vertical, to: .required)
        
        return result
    }()
    
    private lazy var authorLabel: SessionLabelWithProBadge = {
        let result = SessionLabelWithProBadge(proBadgeSize: .mini)
        result.font = .boldSystemFont(ofSize: Values.smallFontSize)
        result.isProBadgeHidden = true
        result.setContentHugging(.vertical, to: .required)
        result.setCompressionResistance(.vertical, to: .required)
        
        return result
    }()

    lazy var snContentView: UIStackView = {
        let result = UIStackView(arrangedSubviews: [])
        result.axis = .vertical
        result.spacing = Values.verySmallSpacing
        result.alignment = .leading
        result.setContentHugging(.horizontal, to: .defaultHigh)
        result.setContentHugging(.vertical, to: .required)
        result.setCompressionResistance(.horizontal, to: .required)
        result.setCompressionResistance(.vertical, to: .required)
        
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
    
    lazy var underBubbleStackView: UIStackView = {
        let result = UIStackView(
            arrangedSubviews: [reactionContainerView, messageStatusStackView]
        )
        result.setContentHuggingPriority(.required, for: .vertical)
        result.setContentCompressionResistancePriority(.required, for: .vertical)
        result.axis = .vertical
        result.spacing = Values.verySmallSpacing
        result.alignment = .trailing
        result.setContentHugging(.vertical, to: .required)
        result.setCompressionResistance(.vertical, to: .required)
        
        return result
    }()

    private lazy var reactionContainerView = ReactionContainerView()
    
    internal lazy var messageStatusStackView: UIStackView = {
        let result: UIStackView = UIStackView(
            arrangedSubviews: [messageStatusLabel, messageStatusImageView, timerView]
        )
        result.axis = .horizontal
        result.alignment = .center
        result.spacing = 2
        
        return result
    }()
    
    private lazy var timerView: DisappearingMessageTimerView = {
        let result: DisappearingMessageTimerView = DisappearingMessageTimerView()
        result.set(.width, to: VisibleMessageCell.messageStatusImageViewSize)
        result.set(.height, to: VisibleMessageCell.messageStatusImageViewSize)
        
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
        result.set(.width, to: VisibleMessageCell.messageStatusImageViewSize)
        result.set(.height, to: VisibleMessageCell.messageStatusImageViewSize)
        
        return result
    }()

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
        
        contentView.addSubview(contentHStack)
        contentView.addSubview(replyButton)
        
        profilePictureViewContainer.addSubview(profilePictureView)
        bubbleBackgroundView.addSubview(bubbleView)
        
        replyButton.addSubview(replyIconImageView)
        
        contentHStackTopConstraint.isActive = true
        contentHStack.pin(
            .leading,
            to: .leading,
            of: contentView,
            withInset: VisibleMessageCell.contactThreadHSpacing
        )
        contentHStack.pin(
            .trailing,
            to: .trailing,
            of: contentView,
            withInset: -VisibleMessageCell.contactThreadHSpacing
        )
        contentHStack
            .pin(.bottom, to: .bottom, of: contentView, withInset: -Values.verySmallSpacing)
            .setting(priority: .defaultHigh)  /// Avoid breaking encapsulated height

        // Profile picture view
        profilePictureView.pin(.bottom, to: .bottom, of: profilePictureViewContainer)
        profilePictureView.pin(.leading, to: .leading, of: profilePictureViewContainer)
        profilePictureView.pin(.trailing, to: .trailing, of: profilePictureViewContainer)
        
        // Bubble background view
        bubbleView.pin(to: bubbleBackgroundView)
        
        // Reply button
        replyIconImageView.center(in: replyButton)
        replyButton.pin(.leading, to: .trailing, of: snContentView, withInset: Values.smallSpacing)
        replyButton.center(.vertical, in: snContentView)
        
        // Reactions container
        reactionContainerView.set(.width, lessThanOrEqualTo: .width, of: underBubbleStackView)
    }
    
    // MARK: - Updating
    
    override func update(
        with cellViewModel: MessageViewModel,
        playbackInfo: ConversationViewModel.PlaybackInfo?,
        showExpandedReactions: Bool,
        shouldExpanded: Bool,
        lastSearchText: String?,
        tableSize: CGSize,
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
        contentHStackTopConstraint.constant = (shouldAddTopInset ? Values.mediumSpacing : 0)
        
        let isGroupThread: Bool = (
            cellViewModel.threadVariant == .community ||
            cellViewModel.threadVariant == .legacyGroup ||
            cellViewModel.threadVariant == .group
        )
        
        // Profile picture view (should always be handled as a standard 'contact' profile picture)
        let profileShouldBeVisible: Bool = (
            isGroupThread &&
            cellViewModel.canHaveProfile &&
            cellViewModel.shouldShowDisplayPicture
        )
        profilePictureView.isHidden = !cellViewModel.canHaveProfile
        profilePictureView.alpha = (profileShouldBeVisible ? 1 : 0)
        profilePictureView.setDataManager(dependencies[singleton: .imageDataManager])
        profilePictureView.update(
            publicKey: cellViewModel.authorId,
            threadVariant: .contact,    // Always show the display picture in 'contact' mode
            displayPictureUrl: nil,
            profile: cellViewModel.profile,
            profileIcon: (cellViewModel.isSenderModeratorOrAdmin ? .crown : .none),
            using: dependencies
        )
       
        // Bubble view
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
            tableSize: tableSize,
            using: dependencies
        )
        
        bubbleView.accessibilityIdentifier = "Message body"
        bubbleView.accessibilityLabel = bodyTappableLabel?.attributedText?.string
        bubbleView.isAccessibilityElement = true
        
        // Author label
        authorLabel.isHidden = !cellViewModel.shouldShowAuthorName
        authorLabel.text = cellViewModel.authorNameSuppressedId
        authorLabel.extraText = cellViewModel.authorName.replacingOccurrences(of: cellViewModel.authorNameSuppressedId, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        authorLabel.themeTextColor = .textPrimary
        authorLabel.isProBadgeHidden = !cellViewModel.proFeatures.contains(.proBadge)
        
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
        
        // Reaction view
        reactionContainerView.isHidden = cellViewModel.reactionInfo.isEmpty
        populateReaction(
            for: cellViewModel,
            maxWidth: VisibleMessageCell.getMaxWidth(
                for: cellViewModel,
                cellWidth: tableSize.width,
                includingOppositeGutter: false
            ),
            showExpandedReactions: showExpandedReactions
        )
        
        // Message status image view
        let (image, statusText, tintColor) = cellViewModel.state.statusIconInfo(
            variant: cellViewModel.variant,
            hasBeenReadByRecipient: cellViewModel.hasBeenReadByRecipient,
            hasAttachments: !cellViewModel.attachments.isEmpty
        )
        messageStatusLabel.text = statusText
        messageStatusLabel.themeTextColor = tintColor
        messageStatusImageView.image = image
        messageStatusLabel.accessibilityIdentifier = "Message sent status: \(statusText ?? "invalid")"
        messageStatusImageView.themeTintColor = tintColor
        messageStatusStackView.isHidden = (
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
        
        // Hide the underBubbleStackView if all of it's content is hidden
        underBubbleStackView.isHidden = !underBubbleStackView.arrangedSubviews.contains { !$0.isHidden }
        
        if cellViewModel.variant.isOutgoing {
            leadingSpacer.isHidden = false
            trailingSpacer.isHidden = true
            
            snContentView.alignment = .trailing
            underBubbleStackView.alignment = .trailing
        }
        else {
            leadingSpacer.isHidden = true
            trailingSpacer.isHidden = false
            contentHStack.spacing = (cellViewModel.canHaveProfile ? VisibleMessageCell.groupThreadHSpacing : 0)
            
            snContentView.alignment = .leading
            underBubbleStackView.alignment = .leading
        }
    }

    private func populateContentView(
        for cellViewModel: MessageViewModel,
        playbackInfo: ConversationViewModel.PlaybackInfo?,
        shouldExpanded: Bool,
        lastSearchText: String?,
        tableSize: CGSize,
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
                maxWidth: (
                    VisibleMessageCell.getMaxWidth(
                        for: cellViewModel,
                        cellWidth: tableSize.width
                    ) - 2 * inset
                )
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
            let maxWidth: CGFloat = (
                VisibleMessageCell.getMaxWidth(
                    for: cellViewModel,
                    cellWidth: tableSize.width
                ) - 2 * inset)
            let lineHeight: CGFloat = UIFont.systemFont(ofSize: VisibleMessageCell.getFontSize(for: cellViewModel)).lineHeight
            
            if let linkPreview: LinkPreview = cellViewModel.linkPreview {
                switch linkPreview.variant {
                    case .standard:
                        // Stack view
                        let stackView = UIStackView(arrangedSubviews: [])
                        stackView.axis = .vertical
                        stackView.spacing = 2
                    
                        let linkPreviewView: LinkPreviewView = LinkPreviewView(
                            maxWidth: maxWidth,
                            using: dependencies
                        )
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
                        stackView.addArrangedSubview(linkPreviewView)
                        readMoreButton.themeTextColor = bodyLabelTextColor
                        let maxHeight: CGFloat = VisibleMessageCell.getMaxHeightAfterTruncation(for: cellViewModel)
                        self.bodayTappableLabelHeightConstraint = linkPreviewView.bodyTappableLabel?.set(
                            .height,
                            to: (shouldExpanded ? linkPreviewView.bodyTappableLabelHeight : min(linkPreviewView.bodyTappableLabelHeight, maxHeight))
                        )
                        if ((linkPreviewView.bodyTappableLabelHeight - maxHeight >= lineHeight) && !shouldExpanded) {
                            stackView.addArrangedSubview(readMoreButton)
                            readMoreButton.isHidden = false
                            readMoreButton.transform = CGAffineTransform(translationX: inset, y: 0)
                        }
                    
                        bubbleView.addSubview(stackView)
                        stackView.pin([UIView.HorizontalEdge.leading, UIView.HorizontalEdge.trailing, UIView.VerticalEdge.top], to: bubbleView)
                        stackView.pin(.bottom, to: .bottom, of: bubbleView, withInset: -inset)
                        snContentView.addArrangedSubview(bubbleBackgroundView)
                        self.bodyTappableLabel = linkPreviewView.bodyTappableLabel
                        self.bodyTappableLabelHeight = linkPreviewView.bodyTappableLabelHeight
                        
                        
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
                stackView.setContentHugging(.vertical, to: .required)
                stackView.setCompressionResistance(.vertical, to: .required)
                
                // Quote view
                if let quotedInfo: MessageViewModel.QuotedInfo = cellViewModel.quotedInfo {
                    let hInset: CGFloat = 2
                    let quoteView: QuoteView = QuoteView(
                        for: .regular,
                        authorName: quotedInfo.authorName,
                        authorHasProBadge: quotedInfo.proFeatures.contains(.proBadge),
                        quotedText: quotedInfo.body,
                        threadVariant: cellViewModel.threadVariant,
                        currentUserSessionIds: cellViewModel.currentUserSessionIds,
                        direction: (cellViewModel.variant.isOutgoing ? .outgoing : .incoming),
                        attachment: quotedInfo.attachment,
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
                bodyTappableLabel.numberOfLines = shouldExpanded ? 0 : VisibleMessageCell.maxNumberOfLinesAfterTruncation
                
                if ((height - maxHeight >= lineHeight) && !shouldExpanded) {
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
        let maxWidth: CGFloat = (
            VisibleMessageCell.getMaxWidth(
                for: cellViewModel,
                cellWidth: tableSize.width
            ) - 2 * inset
        )
        let lineHeight: CGFloat = UIFont.systemFont(ofSize: VisibleMessageCell.getFontSize(for: cellViewModel)).lineHeight
        
        switch (cellViewModel.quotedInfo, cellViewModel.body) {
            /// Both quote and body
            case (.some(let quotedInfo), .some(let body)) where !body.isEmpty:
                // Stack view
                let stackView = UIStackView(arrangedSubviews: [])
                stackView.axis = .vertical
                stackView.spacing = 2
                
                // Quote view
                let hInset: CGFloat = 2
                let quoteView: QuoteView = QuoteView(
                    for: .regular,
                    authorName: quotedInfo.authorName,
                    authorHasProBadge: quotedInfo.proFeatures.contains(.proBadge),
                    quotedText: quotedInfo.body,
                    threadVariant: cellViewModel.threadVariant,
                    currentUserSessionIds: cellViewModel.currentUserSessionIds,
                    direction: (cellViewModel.variant.isOutgoing ? .outgoing : .incoming),
                    attachment: quotedInfo.attachment,
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
                bodyTappableLabel.numberOfLines = shouldExpanded ? 0 : VisibleMessageCell.maxNumberOfLinesAfterTruncation
                
                if ((height - maxHeight >= lineHeight) && !shouldExpanded) {
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
                bodyTappableLabel.numberOfLines = shouldExpanded ? 0 : VisibleMessageCell.maxNumberOfLinesAfterTruncation
                
                if ((height - maxHeight > UIFont.systemFont(ofSize: VisibleMessageCell.getFontSize(for: cellViewModel)).lineHeight) && !shouldExpanded) {
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
            case (.some(let quotedInfo), _):
                let quoteView: QuoteView = QuoteView(
                    for: .regular,
                    authorName: quotedInfo.authorName,
                    authorHasProBadge: quotedInfo.proFeatures.contains(.proBadge),
                    quotedText: quotedInfo.body,
                    threadVariant: cellViewModel.threadVariant,
                    currentUserSessionIds: cellViewModel.currentUserSessionIds,
                    direction: (cellViewModel.variant.isOutgoing ? .outgoing : .incoming),
                    attachment: quotedInfo.attachment,
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
                let maxMessageWidth: CGFloat = VisibleMessageCell.getMaxWidth(
                    for: cellViewModel,
                    cellWidth: tableSize.width
                )
                let albumView = MediaAlbumView(
                    items: cellViewModel.attachments.filter { $0.isVisualMedia },
                    isOutgoing: cellViewModel.variant.isOutgoing,
                    maxMessageWidth: maxMessageWidth,
                    using: dependencies
                )
                self.albumView = albumView
                let size = getSize(for: cellViewModel, tableSize: tableSize)
                albumView.set(.width, to: size.width)
                albumView.set(.height, to: size.height)
                albumView.isAccessibilityElement = true
                albumView.accessibilityLabel = "contentDescriptionMediaMessage".localized()
                snContentView.addArrangedSubview(albumView)
            
            case .voiceMessage:
                guard let attachment: Attachment = cellViewModel.attachments.first(where: { $0.isAudio }) else {
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
                guard let attachment: Attachment = cellViewModel.attachments.first else { return }
                
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
        let reactions: OrderedDictionary<EmojiWithSkinTones, ReactionViewModel> = cellViewModel.reactionInfo
            .reduce(into: OrderedDictionary()) { result, reactionInfo in
                guard let emoji: EmojiWithSkinTones = EmojiWithSkinTones(rawValue: reactionInfo.reaction.emoji) else {
                    return
                }
                
                let isSelfSend: Bool = cellViewModel.currentUserSessionIds.contains(reactionInfo.reaction.authorId)
                
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
                guard let attachment: Attachment = cellViewModel.attachments.first(where: { $0.isAudio }) else {
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
    
    override func handleLongPress(_ gestureRecognizer: UILongPressGestureRecognizer) {
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

    override func handleTap(_ gestureRecognizer: UITapGestureRecognizer) {
        guard let cellViewModel: MessageViewModel = self.viewModel else { return }

        let location = gestureRecognizer.location(in: self)
        let tappedAuthorName: Bool = (
            authorLabel.bounds.contains(authorLabel.convert(location, from: self)) &&
            !cellViewModel.authorName.isEmpty
        )
        let tappedProfilePicture: Bool = (
            profilePictureView.bounds.contains(profilePictureView.convert(location, from: self)) &&
            cellViewModel.shouldShowDisplayPicture
        )
        
        if tappedAuthorName || tappedProfilePicture {
            delegate?.showUserProfileModal(for: cellViewModel)
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
                bodyTappableLabel?.numberOfLines = 0
                bodyTappableLabel?.invalidateIntrinsicContentSize()
                readMoreButton.isHidden = true
                self.bodyContainerStackView?.removeArrangedSubview(readMoreButton)
                delegate?.handleReadMoreButtonTapped(self, for: cellViewModel)
            } else {
                delegate?.handleItemTapped(cellViewModel, cell: self, cellLocation: location)
            }
        }
    }

    override func handleDoubleTap() {
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
        
        guard cellViewModel.containsOnlyEmoji else { return baselineFontSize }
        
        switch cellViewModel.glyphCount {
            case 1: return baselineFontSize + 30
            case 2: return baselineFontSize + 24
            case 3, 4, 5: return baselineFontSize + 18
            default: return baselineFontSize
        }
    }
    
    public static func getMaxHeightAfterTruncation(for cellViewModel: MessageViewModel) -> CGFloat {
        return CGFloat(maxNumberOfLinesAfterTruncation) * UIFont.systemFont(ofSize: getFontSize(for: cellViewModel)).lineHeight
    }

    private func getSize(for cellViewModel: MessageViewModel, tableSize: CGSize) -> CGSize {
        let mediaAttachments: [Attachment] = cellViewModel.attachments.filter({ $0.isVisualMedia })
        let maxMessageWidth = VisibleMessageCell.getMaxWidth(
            for: cellViewModel,
            cellWidth: tableSize.width
        )
        let defaultSize = MediaAlbumView.layoutSize(forMaxMessageWidth: maxMessageWidth, items: mediaAttachments)
        
        guard
            let firstAttachment: Attachment = mediaAttachments.first,
            let originalWidth: CGFloat = firstAttachment.width.map({ CGFloat($0) }),
            let originalHeight: CGFloat = firstAttachment.height.map({ CGFloat($0) }),
            mediaAttachments.count == 1,
            originalWidth > 0,
            originalHeight > 0
        else { return defaultSize }
        
        // Honor the content aspect ratio for single media
        let originalSize: CGSize = CGSize(width: originalWidth, height: originalHeight)
        var aspectRatio = (originalSize.width / originalSize.height)
        
        // Clamp the aspect ratio so that very thin/wide content still looks alright
        let minAspectRatio: CGFloat = 0.35
        let maxAspectRatio = 1 / minAspectRatio
        aspectRatio = aspectRatio.clamp(minAspectRatio, maxAspectRatio)
        
        // Constraint the image
        let constraintWidth = min(maxMessageWidth, originalSize.width)
        let constraintHeight = min(maxMessageWidth, originalSize.height)
        
        var finalWidth: CGFloat
        var finalHeight: CGFloat
        
        if aspectRatio > 1 {
            finalWidth = constraintWidth
            finalHeight = finalWidth / aspectRatio
        }
        else {
            finalHeight = constraintHeight
            finalWidth = finalHeight * aspectRatio
        }
        
        return CGSize(width: finalWidth, height: finalHeight)
    }

    static func getMaxWidth(
        for cellViewModel: MessageViewModel,
        cellWidth: CGFloat,
        includingOppositeGutter: Bool = true
    ) -> CGFloat {
        let horizontalPadding: CGFloat = (contactThreadHSpacing * 2)
        let isGroupThread: Bool = (
            cellViewModel.threadVariant == .community ||
            cellViewModel.threadVariant == .legacyGroup ||
            cellViewModel.threadVariant == .group
        )
        let profileSpace: CGFloat = {
            guard
                cellViewModel.variant.isIncoming,
                isGroupThread,
                cellViewModel.canHaveProfile
            else { return 0 }
            
            return ProfilePictureView.Size.message.viewSize + groupThreadHSpacing
        }()
        let oppositeEdgePadding: CGFloat = (includingOppositeGutter ? gutterSize : contactThreadHSpacing)
        
        return (cellWidth - horizontalPadding - profileSpace - oppositeEdgePadding)
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
            currentUserSessionIds: cellViewModel.currentUserSessionIds,
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
    
    public static func getBodyTappableLabel(
        for cellViewModel: MessageViewModel,
        with availableWidth: CGFloat,
        textColor: ThemeValue,
        searchText: String?,
        delegate: TappableLabelDelegate?,
        using dependencies: Dependencies
    ) -> (label: TappableLabel, height: CGFloat) {
        let result: TappableLabel = TappableLabel()
        result.setContentHugging(.vertical, to: .required)
        result.setCompressionResistance(.vertical, to: .required)
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
