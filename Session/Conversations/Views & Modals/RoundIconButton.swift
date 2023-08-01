// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit

final class RoundIconButton: UIView {
    private let onTap: () -> ()
    
    // MARK: - Settings
    
    private static let size: CGFloat = 40
    private static let iconSize: CGFloat = 16
    
    // MARK: - Lifecycle
    
    init(image: UIImage?, onTap: @escaping () -> ()) {
        self.onTap = onTap
        
        super.init(frame: CGRect.zero)
        
        setUpViewHierarchy(image: image)
    }
    
    override init(frame: CGRect) {
        preconditionFailure("Use init(delegate:) instead.")
    }
    
    required init?(coder: NSCoder) {
        preconditionFailure("Use init(delegate:) instead.")
    }
    
    private func setUpViewHierarchy(image: UIImage?) {
        // Background & blur
        let backgroundView = UIView()
        backgroundView.themeBackgroundColor = .backgroundSecondary
        backgroundView.alpha = Values.lowOpacity
        addSubview(backgroundView)
        backgroundView.pin(to: self)
        
        let blurView = UIVisualEffectView()
        addSubview(blurView)
        blurView.pin(to: self)
        
        ThemeManager.onThemeChange(observer: blurView) { [weak blurView] theme, _ in
            switch theme.interfaceStyle {
                case .light: blurView?.effect = UIBlurEffect(style: .light)
                default: blurView?.effect = UIBlurEffect(style: .dark)
            }
        }
        
        // Size & shape
        set(.width, to: RoundIconButton.size)
        set(.height, to: RoundIconButton.size)
        layer.cornerRadius = (RoundIconButton.size / 2)
        layer.masksToBounds = true
        
        // Border
        self.themeBorderColor = .borderSeparator
        layer.borderWidth = Values.separatorThickness
        
        // Icon
        let iconImageView = UIImageView(image: image)
        iconImageView.themeTintColor = .textPrimary
        iconImageView.contentMode = .scaleAspectFit
        addSubview(iconImageView)
        iconImageView.center(in: self)
        iconImageView.set(.width, to: RoundIconButton.iconSize)
        iconImageView.set(.height, to: RoundIconButton.iconSize)
        
        // Gesture recognizer
        let tapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tapGestureRecognizer)
    }
    
    // MARK: - Interaction
    
    @objc private func handleTap() {
        onTap()
    }
}
