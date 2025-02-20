// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

final class ThemePreviewView: UIView {
    public static let size: SessionCell.Accessory.Size = .fixed(width: 76, height: 70)
    
    // MARK: - Components
    
    private let previewIncomingMessageView: UIView = {
        let result: UIView = UIView()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.isUserInteractionEnabled = false
        result.layer.cornerRadius = 6
        
        return result
    }()
    
    private let previewOutgoingMessageView: UIView = {
        let result: UIView = UIView()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.isUserInteractionEnabled = false
        result.layer.cornerRadius = 6
        
        return result
    }()
    
    // MARK: - Initializtion
    
    init() {
        super.init(frame: .zero)
        
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("Use init(theme:) instead")
    }
    
    // MARK: - Layout
    
    private func setupUI() {
        isUserInteractionEnabled = false
        layer.cornerRadius = 6
        layer.borderWidth = 1
        
        // Add the UI
        addSubview(previewIncomingMessageView)
        addSubview(previewOutgoingMessageView)
        
        setupLayout()
    }
    
    private func setupLayout() {
        previewIncomingMessageView.pin(.bottom, toCenterOf: self, withInset: -1)
        previewIncomingMessageView.pin(.leading, to: .leading, of: self, withInset: Values.smallSpacing)
        previewIncomingMessageView.set(.width, to: 40)
        previewIncomingMessageView.set(.height, to: 12)
        
        previewOutgoingMessageView.pin(.top, toCenterOf: self, withInset: 1)
        previewOutgoingMessageView.pin(.trailing, to: .trailing, of: self, withInset: -Values.smallSpacing)
        previewOutgoingMessageView.set(.width, to: 40)
        previewOutgoingMessageView.set(.height, to: 12)
    }
    
    // MARK: - Content
    
    fileprivate func update(with theme: Theme) {
        themeBackgroundColorForced = .theme(theme, color: .backgroundPrimary)
        themeBorderColorForced = .theme(theme, color: .borderSeparator)
        
        // Set the appropriate colours
        previewIncomingMessageView.themeBackgroundColorForced = .theme(theme, color: .messageBubble_incomingBackground)
        previewOutgoingMessageView.themeBackgroundColorForced = .theme(theme, color: .defaultPrimary)
    }
}

// MARK: - Info

extension ThemePreviewView: SessionCell.Accessory.CustomView {
    struct Info: Equatable, SessionCell.Accessory.CustomViewInfo {
        typealias View = ThemePreviewView
        
        let theme: Theme
    }
    
    static func create(using dependencies: Dependencies) -> ThemePreviewView {
        return ThemePreviewView()
    }
    
    func update(with info: Info) {
        update(with: info.theme)
    }
}
