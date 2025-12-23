// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

public enum SwipeState {
    case began
    case ended
    case cancelled
}

public class MessageCell: UITableViewCell {
    var dependencies: Dependencies?
    var viewModel: MessageViewModel?
    weak var delegate: MessageCellDelegate?
    open var contextSnapshotView: UIView? { return nil }
    
    public lazy var tapGestureRegonizer: UITapGestureRecognizer = {
        let result: UITapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        result.numberOfTapsRequired = 1
        result.require(toFail: doubleTapGestureRegonizer)
        addGestureRecognizer(result)
        
        return result
    }()
    
    public lazy var doubleTapGestureRegonizer: UITapGestureRecognizer = {
        let result: UITapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        result.numberOfTapsRequired = 2
        addGestureRecognizer(result)
        
        return result
    }()
    
    public lazy var longPressGestureRegonizer: UILongPressGestureRecognizer = {
        let result: UILongPressGestureRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
        addGestureRecognizer(result)
        
        return result
    }()

    // MARK: - Lifecycle
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        
        setUpViewHierarchy()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        
        setUpViewHierarchy()
    }

    func setUpViewHierarchy() {
        themeBackgroundColor = .clear
        
        let selectedBackgroundView = UIView()
        selectedBackgroundView.themeBackgroundColor = .clear
        self.selectedBackgroundView = selectedBackgroundView
    }

    // MARK: - Updating
    
    public override func prepareForReuse() {
        super.prepareForReuse()
        
        self.dependencies = nil
        self.viewModel = nil
        self.tapGestureRegonizer.isEnabled = false
        self.doubleTapGestureRegonizer.isEnabled = false
        self.longPressGestureRegonizer.isEnabled = false
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
        switch viewModel.cellType {
            case .typingIndicator: return TypingIndicatorCell.self
            case .dateHeader: return DateHeaderCell.self
            case .unreadMarker: return UnreadMarkerCell.self
            case .call: return CallMessageCell.self
            case .infoMessage: return InfoMessageCell.self
            case .textOnlyMessage, .mediaMessage, .audio, .voiceMessage, .genericAttachment:
                return VisibleMessageCell.self
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
    func showUserProfileModal(for cellViewModel: MessageViewModel)
    func showReactionList(_ cellViewModel: MessageViewModel, selectedReaction: EmojiWithSkinTones?)
    func needsLayout(for cellViewModel: MessageViewModel, expandingReactions: Bool)
    func handleReadMoreButtonTapped(_ cell: UITableViewCell, for cellViewModel: MessageViewModel)
}

extension MessageCellDelegate {
    func handleItemTapped(_ cellViewModel: MessageViewModel, cell: UITableViewCell, cellLocation: CGPoint) {
        handleItemTapped(cellViewModel, cell: cell, cellLocation: cellLocation)
    }
}
