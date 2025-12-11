// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit

public extension UIView {
    var themeBackgroundColor: ThemeValue? {
        set {
            // First we should remove any gradient that had been added
            self.layer.sublayers?.first(where: { $0 is CAGradientLayer })?.removeFromSuperlayer()
            ThemeManager.set(self, keyPath: \.backgroundColor, to: newValue, as: .backgroundColor)
        }
        get { return nil }
    }
    
    var themeBackgroundColorForced: ForcedThemeValue? {
        set {
            // First we should clear out any dynamic setting
            ThemeManager.remove(self, keyPath: \.backgroundColor)
            
            // Then we should remove any gradient that had been added
            self.layer.sublayers?.first(where: { $0 is CAGradientLayer })?.removeFromSuperlayer()
            
            switch newValue {
                case .color(let color): backgroundColor = color
                case .theme(let theme, let value, let alpha):
                    backgroundColor = (
                        alpha.map { ThemeManager.color(for: .value(value, alpha: $0), in: theme) } ??
                        ThemeManager.color(for: value, in: theme)
                    )
                    
                case .none: backgroundColor = nil
            }
        }
        get { return self.backgroundColor.map { .color($0) } }
    }
    
    var themeTintColor: ThemeValue? {
        set {
            /// The `UIActivityIndicatorView` uses a `color` value instead of `tintColor` so redirect it in case this
            /// is mistakenly used
            switch self {
                case let indicator as UIActivityIndicatorView: indicator.themeColor = newValue
                default: ThemeManager.set(self, keyPath: \.tintColor, to: newValue)
            }
        }
        get { return nil }
    }
    
    var themeBorderColor: ThemeValue? {
        set { ThemeManager.set(self, keyPath: \.layer.borderColor, to: newValue) }
        get { return nil }
    }
    
    var themeBorderColorForced: ForcedThemeValue? {
        set {
            // First we should clear out any dynamic setting
            ThemeManager.remove(self, keyPath: \.layer.borderColor)
            
            switch newValue {
                case .color(let color): layer.borderColor = color.cgColor
                case .theme(let theme, let value, let alpha):
                    layer.borderColor = (
                        alpha.map { ThemeManager.color(for: .value(value, alpha: $0), in: theme) } ??
                        ThemeManager.color(for: value, in: theme)
                    ).cgColor
                    
                case .none: layer.borderColor = nil
            }
        }
        get { return nil }
    }
    
    var themeShadowColor: ThemeValue? {
        set { ThemeManager.set(self, keyPath: \.layer.shadowColor, to: newValue) }
        get { return nil }
    }
}

public extension UILabel {
    var themeTextColor: ThemeValue? {
        set { ThemeManager.set(self, keyPath: \.textColor, to: newValue, as: .textColor) }
        get { return nil }
    }
    
    var themeTextColorForced: ForcedThemeValue? {
        set {
            // First we should clear out any dynamic setting
            ThemeManager.remove(self, keyPath: \.textColor)
            
            switch newValue {
                case .color(let color): textColor = color
                case .theme(let theme, let value, let alpha):
                    textColor = (
                        alpha.map { ThemeManager.color(for: .value(value, alpha: $0), in: theme) } ??
                        ThemeManager.color(for: value, in: theme)
                    )
                    
                case .none: textColor = nil
            }
        }
        get { return self.textColor.map { .color($0) } }
    }
}

public extension UITextView {
    var themeTextColor: ThemeValue? {
        set { ThemeManager.set(self, keyPath: \.textColor, to: newValue, as: .textColor) }
        get { return nil }
    }
    
    var themeTextColorForced: ForcedThemeValue? {
        set {
            // First we should clear out any dynamic setting
            ThemeManager.remove(self, keyPath: \.textColor)
            
            switch newValue {
                case .color(let color): textColor = color
                case .theme(let theme, let value, let alpha):
                    textColor = (
                        alpha.map { ThemeManager.color(for: .value(value, alpha: $0), in: theme) } ??
                        ThemeManager.color(for: value, in: theme)
                    )
                    
                case .none: textColor = nil
            }
        }
        get { return self.textColor.map { .color($0) } }
    }
}

public extension UITextField {
    var themeTextColor: ThemeValue? {
        set { ThemeManager.set(self, keyPath: \.textColor, to: newValue, as: .textColor) }
        get { return nil }
    }
    
    var themeTextColorForced: ForcedThemeValue? {
        set {
            // First we should clear out any dynamic setting
            ThemeManager.remove(self, keyPath: \.textColor)
            
            switch newValue {
                case .color(let color): textColor = color
                case .theme(let theme, let value, let alpha):
                    textColor = (
                        alpha.map { ThemeManager.color(for: .value(value, alpha: $0), in: theme) } ??
                        ThemeManager.color(for: value, in: theme)
                    )
                    
                case .none: textColor = nil
            }
        }
        get { return self.textColor.map { .color($0) } }
    }
}

public extension UIButton {
    func setThemeBackgroundColor(_ value: ThemeValue?, for state: UIControl.State) {
        let keyPath: KeyPath<UIButton, UIImage?> = \.imageView?.image
        
        ThemeManager.storeAndApply(
            self,
            info: [
                .keyPath(keyPath),
                .backgroundColor,
                .color(value),
                .state(state)
            ]
        ) { [weak self] theme in
            guard
                let value: ThemeValue = value,
                let color: UIColor = ThemeManager.resolvedColor(ThemeManager.color(for: value, in: theme))
            else {
                self?.setBackgroundImage(nil, for: state)
                return
            }
            
            self?.setBackgroundImage(color.toImage(), for: state)
        }
    }
    
    func setThemeBackgroundColorForced(_ newValue: ForcedThemeValue?, for state: UIControl.State) {
        let keyPath: KeyPath<UIButton, UIImage?> = \.imageView?.image
        
        // First we should clear out any dynamic setting
        ThemeManager.set(
            self,
            to: ThemeManager.get(for: self)?
                .removing(allWith: .keyPath(keyPath))
        )
        
        switch newValue {
            case .color(let color): self.setBackgroundImage(color.toImage(), for: state)
            case .theme(let theme, let value, let alpha):
                let color: UIColor? = (
                    alpha.map { ThemeManager.color(for: .value(value, alpha: $0), in: theme) } ??
                    ThemeManager.color(for: value, in: theme)
                )
                self.setBackgroundImage(color?.toImage(), for: state)
            
            case .none: self.setBackgroundImage(nil, for: state)
        }
    }
    
    func setThemeTitleColor(_ value: ThemeValue?, for state: UIControl.State) {
        let keyPath: KeyPath<UIButton, UIColor?> = \.titleLabel?.textColor
        
        ThemeManager.storeAndApply(
            self,
            info: [
                .keyPath(keyPath),
                .textColor,
                .color(value),
                .state(state)
            ]
        ) { [weak self] theme in
            guard let value: ThemeValue = value else {
                self?.setTitleColor(nil, for: state)
                return
            }
            
            self?.setTitleColor(
                ThemeManager.resolvedColor(ThemeManager.color(for: value, in: theme)),
                for: state
            )
        }
    }
    
    func setThemeTitleColorForced(_ newValue: ForcedThemeValue?, for state: UIControl.State) {
        let keyPath: KeyPath<UIButton, UIColor?> = \.titleLabel?.textColor
        
        // First we should clear out any dynamic setting
        ThemeManager.set(
            self,
            to: ThemeManager.get(for: self)?
                .removing(allWith: .keyPath(keyPath))
        )
        
        switch newValue {
            case .color(let color): self.setTitleColor(color, for: state)
            case .theme(let theme, let value, let alpha):
                let color: UIColor? = (
                    alpha.map { ThemeManager.color(for: .value(value, alpha: $0), in: theme) } ??
                    ThemeManager.color(for: value, in: theme)
                )
                self.setTitleColor(color, for: state)
            
            case .none: self.setTitleColor(nil, for: state)
        }
    }
}

public extension UISwitch {
    var themeOnTintColor: ThemeValue? {
        set { ThemeManager.set(self, keyPath: \.onTintColor, to: newValue) }
        get { return nil }
    }
}

public extension UIBarButtonItem {
    var themeTintColor: ThemeValue? {
        set { ThemeManager.set(self, keyPath: \.tintColor, to: newValue) }
        get { return nil }
    }
}

public extension UIProgressView {
    var themeProgressTintColor: ThemeValue? {
        set { ThemeManager.set(self, keyPath: \.progressTintColor, to: newValue) }
        get { return nil }
    }
    
    var themeProgressTintColorForced: ForcedThemeValue? {
        set {
            // First we should clear out any dynamic setting
            ThemeManager.remove(self, keyPath: \.progressTintColor)
            
            switch newValue {
                case .color(let color): progressTintColor = color
                case .theme(let theme, let value, let alpha):
                    progressTintColor = (
                        alpha.map { ThemeManager.color(for: .value(value, alpha: $0), in: theme) } ??
                        ThemeManager.color(for: value, in: theme)
                    )
                
                case .none: progressTintColor = nil
            }
        }
        get { return self.progressTintColor.map { .color($0) } }
    }
    
    var themeTrackTintColor: ThemeValue? {
        set { ThemeManager.set(self, keyPath: \.trackTintColor, to: newValue) }
        get { return nil }
    }
}

public extension UISlider {
    var themeMinimumTrackTintColor: ThemeValue? {
        set { ThemeManager.set(self, keyPath: \.minimumTrackTintColor, to: newValue) }
        get { return nil }
    }
    
    var themeMaximumTrackTintColor: ThemeValue? {
        set { ThemeManager.set(self, keyPath: \.maximumTrackTintColor, to: newValue) }
        get { return nil }
    }
}

public extension UIToolbar {
    var themeBarTintColor: ThemeValue? {
        set { ThemeManager.set(self, keyPath: \.barTintColor, to: newValue) }
        get { return nil }
    }
}

public extension UIContextualAction {
    var themeBackgroundColor: ThemeValue? {
        set {
            guard let newValue: ThemeValue = newValue else {
                self.backgroundColor = nil
                return
            }
            
            self.backgroundColor = UIColor(dynamicProvider: { _ in
                ThemeManager.color(for: newValue)
            })
        }
        get { return nil }
    }
}

public extension UIPageControl {
    var themeCurrentPageIndicatorTintColor: ThemeValue? {
        set { ThemeManager.set(self, keyPath: \.currentPageIndicatorTintColor, to: newValue) }
        get { return nil }
    }
    
    var themePageIndicatorTintColor: ThemeValue? {
        set { ThemeManager.set(self, keyPath: \.pageIndicatorTintColor, to: newValue) }
        get { return nil }
    }
}

public extension UIActivityIndicatorView {
    var themeColor: ThemeValue? {
        set { ThemeManager.set(self, keyPath: \.color, to: newValue) }
        get { return nil }
    }
}

public extension GradientView {
    var themeBackgroundGradient: [ThemeValue]? {
        set {
            let keyPath: KeyPath<UIView, UIColor?> = \.backgroundColor
            
            // First we should clear out any dynamic setting
            ThemeManager.remove(self, keyPath: \.backgroundColor)
            
            ThemeManager.storeAndApply(
                self,
                info: [.keyPath(keyPath)]
            ) { [weak self] theme in
                // First we should remove any gradient that had been added
                self?.layer.sublayers?.first(where: { $0 is CAGradientLayer })?.removeFromSuperlayer()
                
                let maybeColors: [CGColor]? = newValue?.compactMap {
                    ThemeManager.color(for: $0, in: theme).cgColor
                }
                
                guard let colors: [CGColor] = maybeColors, colors.count == newValue?.count else {
                    self?.backgroundColor = nil
                    return
                }
                
                let layer: CAGradientLayer = CAGradientLayer()
                layer.frame = (self?.bounds ?? .zero)
                layer.colors = colors
                self?.layer.insertSublayer(layer, at: 0)
            }
        }
        get { return nil }
    }
}

public extension CAShapeLayer {
    @MainActor var themeStrokeColor: ThemeValue? {
        set { ThemeManager.set(self, keyPath: \.strokeColor, to: newValue) }
        get { return nil }
    }
    
    var themeStrokeColorForced: ForcedThemeValue? {
        set {
            // First we should clear out any dynamic setting
            ThemeManager.remove(self, keyPath: \.strokeColor)
            
            switch newValue {
                case .color(let color): strokeColor = color.cgColor
                case .theme(let theme, let value, let alpha):
                    strokeColor = (
                        alpha.map { ThemeManager.color(for: .value(value, alpha: $0), in: theme) } ??
                        ThemeManager.color(for: value, in: theme)
                    ).cgColor
                
                case .none: strokeColor = nil
            }
        }
        get { return self.strokeColor.map { .color(UIColor(cgColor: $0)) } }
    }
    
    @MainActor var themeFillColor: ThemeValue? {
        set { ThemeManager.set(self, keyPath: \.fillColor, to: newValue) }
        get { return nil }
    }
    
    var themeFillColorForced: ForcedThemeValue? {
        set {
            // First we should clear out any dynamic setting
            ThemeManager.remove(self, keyPath: \.fillColor)
            
            switch newValue {
                case .color(let color): fillColor = color.cgColor
                case .theme(let theme, let value, let alpha):
                    fillColor = (
                        alpha.map { ThemeManager.color(for: .value(value, alpha: $0), in: theme) } ??
                        ThemeManager.color(for: value, in: theme)
                    ).cgColor
                
                case .none: fillColor = nil
            }
        }
        get { return self.fillColor.map { .color(UIColor(cgColor: $0)) } }
    }
}

public extension CALayer {
    @MainActor var themeBackgroundColor: ThemeValue? {
        set { ThemeManager.set(self, keyPath: \.backgroundColor, to: newValue, as: .backgroundColor) }
        get { return nil }
    }
    
    var themeBackgroundColorForced: ForcedThemeValue? {
        set {
            // First we should clear out any dynamic setting
            ThemeManager.remove(self, keyPath: \.backgroundColor)
            
            switch newValue {
                case .color(let color): backgroundColor = color.cgColor
                case .theme(let theme, let value, let alpha):
                    backgroundColor = (
                        alpha.map { ThemeManager.color(for: .value(value, alpha: $0), in: theme) } ??
                        ThemeManager.color(for: value, in: theme)
                    ).cgColor
                    
                case .none: backgroundColor = nil
            }
        }
        get { return self.backgroundColor.map { .color(UIColor(cgColor: $0)) } }
    }
    
    @MainActor var themeBorderColor: ThemeValue? {
        set { ThemeManager.set(self, keyPath: \.borderColor, to: newValue) }
        get { return nil }
    }
    
    @MainActor var themeShadowColor: ThemeValue? {
        set { ThemeManager.set(self, keyPath: \.shadowColor, to: newValue) }
        get { return nil }
    }
}

public extension CATextLayer {
    @MainActor var themeForegroundColor: ThemeValue? {
        set { ThemeManager.set(self, keyPath: \.foregroundColor, to: newValue, as: .textColor) }
        get { return nil }
    }
    
    var themeForegroundColorForced: ForcedThemeValue? {
        set {
            // First we should clear out any dynamic setting
            ThemeManager.remove(self, keyPath: \.foregroundColor)
            
            switch newValue {
                case .color(let color): foregroundColor = color.cgColor
                case .theme(let theme, let value, let alpha):
                    foregroundColor = (
                        alpha.map { ThemeManager.color(for: .value(value, alpha: $0), in: theme) } ??
                        ThemeManager.color(for: value, in: theme)
                    ).cgColor
                
                case .none: foregroundColor = nil
            }
        }
        get { return self.foregroundColor.map { .color(UIColor(cgColor: $0)) } }
    }
}

// MARK: - AttributedTextAssignable

public protocol AttributedTextAssignable: AnyObject {
    var attributedTextValue: NSAttributedString? { get set }
}

public protocol DirectAttributedTextAssignable: AttributedTextAssignable {
    var attributedText: NSAttributedString? { get set }
}

extension DirectAttributedTextAssignable {
    public var attributedTextValue: NSAttributedString? {
        get { attributedText }
        set { attributedText = newValue }
    }
}

extension AttributedTextAssignable {
    private var themeAttributedTextValue: ThemedAttributedString? {
        get { attributedTextValue.map { ThemedAttributedString(attributedString: $0) } }
        set { attributedTextValue = newValue?.attributedString }
    }
    @MainActor public var themeAttributedText: ThemedAttributedString? {
        set { ThemeManager.set(self, keyPath: \.themeAttributedTextValue, to: newValue) }
        get { return nil }
    }
}

extension UILabel: DirectAttributedTextAssignable {}
extension UITextField: DirectAttributedTextAssignable {
    private var themeAttributedPlaceholderValue: ThemedAttributedString? {
        get { attributedPlaceholder.map { ThemedAttributedString(attributedString: $0) } }
        set { attributedPlaceholder = newValue?.attributedString }
    }
    @MainActor public var themeAttributedPlaceholder: ThemedAttributedString? {
        set { ThemeManager.set(self, keyPath: \.themeAttributedPlaceholderValue, to: newValue) }
        get { return nil }
    }
}

/// UITextView has a `attributedText: NSAttributedString!` value so we need to conform to a different protocol
extension UITextView: AttributedTextAssignable {
    public var attributedTextValue: NSAttributedString? {
        get { self.attributedText }
        set { self.attributedText = newValue }
    }
}

// MARK: - Convenience

private extension ThemeManager {
    static func color(for value: ThemeValue, in targetTheme: Theme? = nil) -> UIColor {
        let color: UIColor? = ThemeManager.color(
            for: value,
            in: (targetTheme ?? ThemeManager.currentTheme),
            with: ThemeManager.primaryColor
        )
        
        return (color ?? .clear)
    }
}
