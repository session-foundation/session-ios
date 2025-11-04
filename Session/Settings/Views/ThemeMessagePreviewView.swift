// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

final class ThemeMessagePreviewView: UIView {
    public static let size: SessionCell.Accessory.Size = .fillWidthWrapHeight
    
    private let dependencies: Dependencies
    
    // MARK: - Components
    
    private lazy var incomingMessagePreview: UIView = {
        let cell: VisibleMessageCell = VisibleMessageCell()
        cell.update(
            with: MessageViewModel(
                variant: .standardIncoming,
                body: "appearancePreview2".localized(),
                quotedInfo: MessageViewModel.QuotedInfo(previewBody: "appearancePreview1".localized()),
                cellType: .textOnlyMessage
            ),
            playbackInfo: nil,
            showExpandedReactions: false,
            shouldExpanded: false,
            lastSearchText: nil,
            tableSize: UIScreen.main.bounds.size,
            using: dependencies
        )
        cell.contentHStack.removeFromSuperview()
        
        return cell.contentHStack
    }()
    
    private lazy var outgoingMessagePreview: UIView = {
        let cell: VisibleMessageCell = VisibleMessageCell()
        cell.update(
            with: MessageViewModel(
                variant: .standardOutgoing,
                body: "appearancePreview3".localized(),
                cellType: .textOnlyMessage,
                isLast: false // To hide the status indicator
            ),
            playbackInfo: nil,
            showExpandedReactions: false,
            shouldExpanded: false,
            lastSearchText: nil,
            tableSize: UIScreen.main.bounds.size,
            using: dependencies
        )
        cell.contentHStack.removeFromSuperview()
        
        return cell.contentHStack
    }()
    
    // MARK: - Initializtion
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        
        super.init(frame: .zero)
        
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Layout
    
    private func setupUI() {
        addSubview(incomingMessagePreview)
        addSubview(outgoingMessagePreview)
        
        setupLayout()
    }
    
    private func setupLayout() {
        incomingMessagePreview.pin(.top, to: .top, of: self)
        incomingMessagePreview.pin(.leading, to: .leading, of: self)
        incomingMessagePreview.pin(.trailing, to: .trailing, of: self)
        
        outgoingMessagePreview.pin(.top, to: .bottom, of: incomingMessagePreview, withInset: Values.mediumSpacing)
        outgoingMessagePreview.pin(.leading, to: .leading, of: self)
        outgoingMessagePreview.pin(.trailing, to: .trailing, of: self)
        outgoingMessagePreview.pin(.bottom, to: .bottom, of: self)
    }
}

// MARK: - Info

extension ThemeMessagePreviewView: SessionCell.Accessory.CustomView {
    struct Info: Equatable, SessionCell.Accessory.CustomViewInfo {
        typealias View = ThemeMessagePreviewView
    }
    
    static func create(maxContentWidth: CGFloat, using dependencies: Dependencies) -> ThemeMessagePreviewView {
        return ThemeMessagePreviewView(using: dependencies)
    }
    
    // No need to do anything (theme with auto-update)
    func update(with info: Info) {}
}
