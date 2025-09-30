// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionMessagingKit
import SessionUtilitiesKit

public enum SwipeState {
    case began
    case ended
    case cancelled
}

public enum GestureRecognizerType {
    case tap, longPress, doubleTap
}

public class MessageCell: UITableViewCell {
    var dependencies: Dependencies?
    var viewModel: MessageViewModel?
    weak var delegate: MessageCellDelegate?
    open var contextSnapshotView: UIView? { return nil }
    open var allowedGestureRecognizers: Set<GestureRecognizerType> { return [] } // Override to have gestures

    // MARK: - Lifecycle
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        
        setUpViewHierarchy()
        setUpGestureRecognizers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        
        setUpViewHierarchy()
        setUpGestureRecognizers()
    }

    func setUpViewHierarchy() {
        themeBackgroundColor = .clear
        
        let selectedBackgroundView = UIView()
        selectedBackgroundView.themeBackgroundColor = .clear
        self.selectedBackgroundView = selectedBackgroundView
    }

    func setUpGestureRecognizers() {
        var tapGestureRecognizer: UITapGestureRecognizer?
        var doubleTapGestureRecognizer: UITapGestureRecognizer?
        
        if allowedGestureRecognizers.contains(.tap) {
            let tapGesture: UITapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap))
            tapGesture.numberOfTapsRequired = 1
            addGestureRecognizer(tapGesture)
            tapGestureRecognizer = tapGesture
        }
        
        if allowedGestureRecognizers.contains(.doubleTap) {
            let doubleTapGesture: UITapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
            doubleTapGesture.numberOfTapsRequired = 2
            addGestureRecognizer(doubleTapGesture)
            doubleTapGestureRecognizer = doubleTapGesture
        }
        
        if allowedGestureRecognizers.contains(.longPress) {
            let longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
            addGestureRecognizer(longPressGesture)
        }
        
        // If we have both tap and double tap gestures then the single tap should fail if a double tap occurs
        if let tapGesture: UITapGestureRecognizer = tapGestureRecognizer, let doubleTapGesture: UITapGestureRecognizer = doubleTapGestureRecognizer {
            tapGesture.require(toFail: doubleTapGesture)
        }
    }

    // MARK: - Updating
    
    public override func prepareForReuse() {
        super.prepareForReuse()
        
        self.dependencies = nil
        self.viewModel = nil
    }
    
    func update(
        with cellViewModel: MessageViewModel,
        playbackInfo: ConversationViewModel.PlaybackInfo?,
        showExpandedReactions: Bool,
        shouldExpanded: Bool,
        lastSearchText: String?,
        tableSize: CGSize,
        using dependencies: Dependencies
    ) {
        preconditionFailure("Must be overridden by subclasses.")
    }
    
    /// This is a cut-down version of the 'update' function which doesn't re-create the UI (it should be used for dynamically-updating content
    /// like playing inline audio/video)
    func dynamicUpdate(with cellViewModel: MessageViewModel, playbackInfo: ConversationViewModel.PlaybackInfo?) {
        preconditionFailure("Must be overridden by subclasses.")
    }

    // MARK: - Convenience
    
    static func cellType(for viewModel: MessageViewModel) -> MessageCell.Type {
        guard viewModel.cellType != .typingIndicator else { return TypingIndicatorCell.self }
        guard viewModel.cellType != .dateHeader else { return DateHeaderCell.self }
        guard viewModel.cellType != .unreadMarker else { return UnreadMarkerCell.self }
        
        switch viewModel.variant {
            case .standardOutgoing, .standardIncoming, ._legacyStandardIncomingDeleted,
                .standardIncomingDeleted, .standardOutgoingDeleted, .standardIncomingDeletedLocally,
                .standardOutgoingDeletedLocally:
                return VisibleMessageCell.self
                
            case .infoLegacyGroupCreated, .infoLegacyGroupUpdated, .infoLegacyGroupCurrentUserLeft,
                .infoGroupCurrentUserLeaving, .infoGroupCurrentUserErrorLeaving,
                .infoDisappearingMessagesUpdate, .infoScreenshotNotification, .infoMediaSavedNotification,
                .infoMessageRequestAccepted, .infoGroupInfoInvited, .infoGroupInfoUpdated, .infoGroupMembersUpdated:
                return InfoMessageCell.self
                
            case .infoCall:
                return CallMessageCell.self
        }
    }
    
    // MARK: - Gesture events
    @objc
    func handleLongPress(_ gestureRecognizer: UILongPressGestureRecognizer) {}

    @objc
    func handleTap(_ gestureRecognizer: UITapGestureRecognizer) {}

    @objc
    func handleDoubleTap() {}
}

// MARK: - MessageCellDelegate

protocol MessageCellDelegate: ReactionDelegate {
    func handleItemLongPressed(_ cellViewModel: MessageViewModel)
    func handleItemTapped(_ cellViewModel: MessageViewModel, cell: UITableViewCell, cellLocation: CGPoint)
    func handleItemDoubleTapped(_ cellViewModel: MessageViewModel)
    func handleItemSwiped(_ cellViewModel: MessageViewModel, state: SwipeState)
    func openUrl(_ urlString: String)
    func handleReplyButtonTapped(for cellViewModel: MessageViewModel)
    func startThread(with sessionId: String, openGroupServer: String?, openGroupPublicKey: String?)
    func showReactionList(_ cellViewModel: MessageViewModel, selectedReaction: EmojiWithSkinTones?)
    func needsLayout(for cellViewModel: MessageViewModel, expandingReactions: Bool)
    func handleReadMoreButtonTapped(_ cell: UITableViewCell, for cellViewModel: MessageViewModel)
}

extension MessageCellDelegate {
    func handleItemTapped(_ cellViewModel: MessageViewModel, cell: UITableViewCell, cellLocation: CGPoint) {
        handleItemTapped(cellViewModel, cell: cell, cellLocation: cellLocation)
    }
}
