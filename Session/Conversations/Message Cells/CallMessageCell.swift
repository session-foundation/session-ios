// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import AVFAudio
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

final class CallMessageCell: MessageCell {
    private static let iconSize: CGFloat = 16
    private static let timerViewSize: CGFloat = 16
    private static let inset = Values.mediumSpacing
    private static let verticalInset = Values.smallSpacing
    private static let horizontalInset = Values.mediumSmallSpacing
    private static let margin = UIScreen.main.bounds.width * 0.1
    
    private var isHandlingLongPress: Bool = false
    
    override var contextSnapshotView: UIView? { return container }
    
    // MARK: - UI
    
    private lazy var topConstraint: NSLayoutConstraint = mainStackView.pin(.top, to: .top, of: self, withInset: CallMessageCell.inset)
    
    private lazy var iconImageView: UIImageView = {
        let result: UIImageView = UIImageView()
        result.themeTintColor = .textPrimary
        result.set(.width, to: CallMessageCell.iconSize)
        result.set(.height, to: CallMessageCell.iconSize)
        result.setContentHugging(.horizontal, to: .required)
        result.setCompressionResistance(.horizontal, to: .required)
        
        return result
    }()
    private lazy var infoImageView: UIImageView = {
        let result: UIImageView = UIImageView(
            image: UIImage(named: "ic_info")?
                .withRenderingMode(.alwaysTemplate)
        )
        result.themeTintColor = .textPrimary
        result.set(.width, to: CallMessageCell.iconSize)
        result.set(.height, to: CallMessageCell.iconSize)
        result.setContentHugging(.horizontal, to: .required)
        result.setCompressionResistance(.horizontal, to: .required)
        
        return result
    }()
    
    private lazy var timerView: DisappearingMessageTimerView = DisappearingMessageTimerView()
    private lazy var timerViewContainer: UIView = {
        let result: UIView = UIView()
        result.addSubview(timerView)
        result.set(.height, to: CallMessageCell.timerViewSize)
        timerView.center(in: result)
        timerView.set(.height, to: CallMessageCell.timerViewSize)
        
        return result
    }()
    
    private lazy var label: UILabel = {
        let result: UILabel = UILabel()
        result.font = .systemFont(ofSize: Values.mediumFontSize)
        result.themeTextColor = .textPrimary
        result.textAlignment = .center
        result.lineBreakMode = .byWordWrapping
        result.numberOfLines = 0
        result.setContentHugging(.horizontal, to: .defaultLow)
        result.setCompressionResistance(.horizontal, to: .defaultLow)
        
        return result
    }()
    
    private lazy var contentStackView: UIStackView = {
        let result: UIStackView = UIStackView(arrangedSubviews: [iconImageView, label, infoImageView])
        result.axis = .horizontal
        result.alignment = .center
        result.spacing = CallMessageCell.horizontalInset
        
        return result
    }()
    
    private lazy var container: UIStackView = {
        let result: UIStackView = UIStackView()
        result.themeBackgroundColor = .backgroundSecondary
        result.layer.cornerRadius = 18
        
        return result
    }()
    
    private lazy var mainStackView: UIStackView = {
        let result: UIStackView = UIStackView(arrangedSubviews: [ timerViewContainer, container ])
        result.axis = .vertical
        result.spacing = Values.smallSpacing
        result.alignment = .fill
        
        return result
    }()
    
    // MARK: - Lifecycle
    
    override func setUpViewHierarchy() {
        super.setUpViewHierarchy()
        
        container.addSubview(contentStackView)
        addSubview(mainStackView)
        
        contentStackView.pin(.top, to: .top, of: container, withInset: CallMessageCell.verticalInset)
        contentStackView.pin(.leading, to: .leading, of: container, withInset: CallMessageCell.horizontalInset)
        contentStackView.pin(.trailing, to: .trailing, of: container, withInset: -CallMessageCell.horizontalInset)
        contentStackView.pin(.bottom, to: .bottom, of: container, withInset: -CallMessageCell.verticalInset)

        topConstraint.isActive = true
        mainStackView.pin(.left, to: .left, of: self, withInset: CallMessageCell.margin)
        mainStackView.pin(.right, to: .right, of: self, withInset: -CallMessageCell.margin)
        mainStackView.pin(.bottom, to: .bottom, of: self, withInset: -CallMessageCell.inset)
    }
    
    // MARK: - Updating
    
    override func update(
        with cellViewModel: MessageViewModel,
        playbackInfo: ConversationViewModel.PlaybackInfo?,
        showExpandedReactions: Bool,
        shouldExpanded: Bool,
        lastSearchText: String?,
        tableSize: CGSize,
        displayNameRetriever: DisplayNameRetriever,
        using dependencies: Dependencies
    ) {
        guard
            cellViewModel.variant == .infoCall,
            let infoMessageData: Data = (cellViewModel.rawBody ?? "").data(using: .utf8),
            let messageInfo: CallMessage.MessageInfo = try? JSONDecoder().decode(
                CallMessage.MessageInfo.self,
                from: infoMessageData
            )
        else { return }
        
        self.dependencies = dependencies
        self.accessibilityIdentifier = "Control message"
        self.isAccessibilityElement = true
        self.viewModel = cellViewModel
        self.tapGestureRegonizer.isEnabled = cellViewModel.cellType.supportedGestures.contains(.tap)
        self.doubleTapGestureRegonizer.isEnabled = cellViewModel.cellType.supportedGestures.contains(.doubleTap)
        self.longPressGestureRegonizer.isEnabled = cellViewModel.cellType.supportedGestures.contains(.longPress)
        self.topConstraint.constant = (cellViewModel.shouldShowDateHeader ? 0 : CallMessageCell.inset)
        
        iconImageView.image = {
            switch messageInfo.state {
                case .outgoing: return UIImage(named: "CallOutgoing")?.withRenderingMode(.alwaysTemplate)
                case .incoming: return UIImage(named: "CallIncoming")?.withRenderingMode(.alwaysTemplate)
                case .missed, .permissionDenied, .permissionDeniedMicrophone:
                    return UIImage(named: "CallMissed")?.withRenderingMode(.alwaysTemplate)
                default: return nil
            }
        }()
        iconImageView.themeTintColor = {
            switch messageInfo.state {
                case .outgoing, .incoming: return .textPrimary
                case .missed, .permissionDenied, .permissionDeniedMicrophone: return .danger
                default: return nil
            }
        }()
        iconImageView.isHidden = (iconImageView.image == nil)
        
        let shouldShowInfoIcon: Bool = (
            (
                messageInfo.state == .permissionDenied &&
                !dependencies.mutate(cache: .libSession, { $0.get(.areCallsEnabled) })
            ) || (
                messageInfo.state == .permissionDeniedMicrophone &&
                Permissions.microphone != .granted
            )
        )
        infoImageView.isHidden = !shouldShowInfoIcon
        
        label.text = cellViewModel.body
        
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
            timerView.themeTintColor = .textSecondary
            timerViewContainer.isHidden = false
        }
        else {
            timerViewContainer.isHidden = true
        }
    }
    
    override func dynamicUpdate(with cellViewModel: MessageViewModel, playbackInfo: ConversationViewModel.PlaybackInfo?) {
    }
    
    // MARK: - Interaction
    
    override func handleLongPress(_ gestureRecognizer: UILongPressGestureRecognizer) {
        if [ .ended, .cancelled, .failed ].contains(gestureRecognizer.state) {
            isHandlingLongPress = false
            return
        }
        guard !isHandlingLongPress, let cellViewModel: MessageViewModel = self.viewModel else { return }
        
        delegate?.handleItemLongPressed(cellViewModel)
        isHandlingLongPress = true
    }
    
    override func handleTap(_ gestureRecognizer: UITapGestureRecognizer) {
        guard
            let dependencies: Dependencies = self.dependencies,
            let cellViewModel: MessageViewModel = self.viewModel,
            cellViewModel.variant == .infoCall,
            let infoMessageData: Data = (cellViewModel.rawBody ?? "").data(using: .utf8),
            let messageInfo: CallMessage.MessageInfo = try? JSONDecoder(using: dependencies).decode(
                CallMessage.MessageInfo.self,
                from: infoMessageData
            )
        else { return }
        
        // Should only be tappable if the info icon is visible
        guard
            (
                messageInfo.state == .permissionDenied &&
                !dependencies.mutate(cache: .libSession, { $0.get(.areCallsEnabled) })
            ) || (
                messageInfo.state == .permissionDeniedMicrophone &&
                Permissions.microphone != .granted
            )
        else { return }
        
        self.delegate?.handleItemTapped(cellViewModel, cell: self, cellLocation: gestureRecognizer.location(in: self))
    }
}
