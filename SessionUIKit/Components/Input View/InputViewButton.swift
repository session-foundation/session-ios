// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit

public final class InputViewButton: UIView {
    private let icon: UIImage?
    private let isSendButton: Bool
    private weak var delegate: InputViewButtonDelegate?
    private let hasOpaqueBackground: Bool
    private let onTap: (() -> Void)?
    private lazy var widthConstraint = set(.width, to: InputViewButton.size)
    private lazy var heightConstraint = set(.height, to: InputViewButton.size)
    private var longPressTimer: Timer?
    private var isLongPress = false
    public var isSoftDisabled = false
    
    // MARK: - UI Components
    
    private lazy var backgroundView: UIView = UIView()
    private lazy var iconImageView: UIImageView = UIImageView()
    
    // MARK: - Settings
    
    public static let size: CGFloat = 40
    public static let expandedSize: CGFloat = 48
    public static let iconSize: CGFloat = 20
    
    // MARK: - Lifecycle
    
    public init(
        icon: UIImage?,
        isSendButton: Bool = false,
        delegate: InputViewButtonDelegate? = nil,
        hasOpaqueBackground: Bool = false,
        onTap: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.isSendButton = isSendButton
        self.delegate = delegate
        self.hasOpaqueBackground = hasOpaqueBackground
        self.onTap = onTap
        
        super.init(frame: CGRect.zero)
        
        setUpViewHierarchy()
        self.isAccessibilityElement = true
    }
    
    override init(frame: CGRect) {
        preconditionFailure("Use init(icon:delegate:) instead.")
    }
    
    required init?(coder: NSCoder) {
        preconditionFailure("Use init(icon:delegate:) instead.")
    }
    
    private func setUpViewHierarchy() {
        themeBackgroundColor = .clear
        
        if hasOpaqueBackground {
            let backgroundView: UIView = UIView()
            backgroundView.themeBackgroundColor = .inputButton_background
            backgroundView.alpha = Values.lowOpacity
            addSubview(backgroundView)
            backgroundView.pin(to: self)
            
            let blurView: UIVisualEffectView = UIVisualEffectView()
            addSubview(blurView)
            blurView.pin(to: self)
            
            ThemeManager.onThemeChange(observer: blurView) { [weak blurView] theme, _, _ in
                blurView?.effect = UIBlurEffect(style: theme.blurStyle)
            }
            
            themeBorderColor = .borderSeparator
            layer.borderWidth = Values.separatorThickness
        }
        
        backgroundView.themeBackgroundColor = (isSendButton ? .primary : .inputButton_background)
        backgroundView.alpha = (isSendButton ? 1 : Values.lowOpacity)
        addSubview(backgroundView)
        backgroundView.pin(to: self)
        
        layer.cornerRadius = (InputViewButton.size / 2)
        layer.masksToBounds = true
        isUserInteractionEnabled = true
        widthConstraint.isActive = true
        heightConstraint.isActive = true
        
        iconImageView.image = icon?.withRenderingMode(.alwaysTemplate)
        iconImageView.themeTintColor = (isSendButton ? .black : .textPrimary)
        iconImageView.contentMode = .scaleAspectFit
        addSubview(iconImageView)
        iconImageView.center(in: self)
        iconImageView.set(.width, to: InputViewButton.iconSize)
        iconImageView.set(.height, to: InputViewButton.iconSize)
    }
    
    // MARK: - Animation
    
    private func animate(
        to size: CGFloat,
        themeBackgroundColor: ThemeValue,
        themeTintColor: ThemeValue,
        alpha: CGFloat
    ) {
        let frame = CGRect(center: center, size: CGSize(width: size, height: size))
        widthConstraint.constant = size
        heightConstraint.constant = size
        
        UIView.animate(withDuration: 0.25) {
            self.layoutIfNeeded()
            self.frame = frame
            self.layer.cornerRadius = (size / 2)
            self.iconImageView.themeTintColor = themeTintColor
            self.backgroundView.themeBackgroundColor = themeBackgroundColor
            self.backgroundView.alpha = alpha
        }
    }
    
    private func expand() {
        animate(
            to: InputViewButton.expandedSize,
            themeBackgroundColor: .primary,
            themeTintColor: .black,
            alpha: 1
        )
    }
    
    private func collapse() {
        animate(
            to: InputViewButton.size,
            themeBackgroundColor: (isSendButton ? .primary : .inputButton_background),
            themeTintColor: (isSendButton ? .black : .textPrimary),
            alpha: (isSendButton ? 1 : Values.lowOpacity)
        )
    }
    
    public func updateAppearance(isEnabled: Bool) {
        iconImageView.themeTintColor = isEnabled ? .textPrimary : .disabled
        backgroundView.themeBackgroundColor = isEnabled ? .inputButton_background : .disabled
    }
    
    // MARK: - Interaction
    
    // We want to detect both taps and long presses
    
    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !isSoftDisabled && isUserInteractionEnabled else { return }
        
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        expand()
        invalidateLongPressIfNeeded()
        longPressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false, block: { [weak self] _ in
            self?.isLongPress = true
            self?.delegate?.handleInputViewButtonLongPressBegan(self)
        })
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !isSoftDisabled && isUserInteractionEnabled else { return }
        
        if isLongPress {
            delegate?.handleInputViewButtonLongPressMoved(self, with: touches.first)
        }
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isUserInteractionEnabled else { return }
        guard !isSoftDisabled else {
            delegate?.handleInputViewButtonTapped(self)
            onTap?()
            return
        }
        
        collapse()
        if !isLongPress {
            delegate?.handleInputViewButtonTapped(self)
            onTap?()
        } else {
            delegate?.handleInputViewButtonLongPressEnded(self, with: touches.first)
        }
        invalidateLongPressIfNeeded()
    }
    
    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        collapse()
        invalidateLongPressIfNeeded()
    }

    private func invalidateLongPressIfNeeded() {
        longPressTimer?.invalidate()
        isLongPress = false
    }
}

// MARK: - Delegate

public protocol InputViewButtonDelegate: AnyObject {
    @MainActor func handleInputViewButtonTapped(_ inputViewButton: InputViewButton)
    @MainActor func handleInputViewButtonLongPressBegan(_ inputViewButton: InputViewButton?)
    @MainActor func handleInputViewButtonLongPressMoved(_ inputViewButton: InputViewButton, with touch: UITouch?)
    @MainActor func handleInputViewButtonLongPressEnded(_ inputViewButton: InputViewButton, with touch: UITouch?)
}
