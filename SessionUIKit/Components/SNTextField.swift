// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit

public final class SNTextField: UITextField {
    private let usesDefaultHeight: Bool
    private let height: CGFloat
    private let horizontalInset: CGFloat
    private let verticalInset: CGFloat

    static let height: CGFloat = isIPhone5OrSmaller ? CGFloat(48) : CGFloat(80)
    public static let cornerRadius: CGFloat = 8
    
    public override var placeholder: String? {
        didSet {
            themeAttributedPlaceholder = placeholder.map {
                ThemedAttributedString(
                    string: $0,
                    attributes: [
                        .themeForegroundColor: ThemeValue.textSecondary
                    ]
                )
            }
        }
    }
    
    @objc(initWithPlaceholder:usesDefaultHeight:)
    public convenience init(placeholder: String, usesDefaultHeight: Bool) {
        self.init(placeholder: placeholder, usesDefaultHeight: usesDefaultHeight, customHeight: nil, customHorizontalInset: nil, customVerticalInset: nil)
    }
    
    public init(placeholder: String, usesDefaultHeight: Bool = true, customHeight: CGFloat? = nil, customHorizontalInset: CGFloat? = nil, customVerticalInset: CGFloat? = nil) {
        self.usesDefaultHeight = usesDefaultHeight
        self.height = customHeight ?? SNTextField.height
        self.horizontalInset = customHorizontalInset ?? (isIPhone5OrSmaller ? Values.mediumSpacing : Values.largeSpacing)
        self.verticalInset = customVerticalInset ?? (isIPhone5OrSmaller ? Values.smallSpacing : Values.largeSpacing)
        
        super.init(frame: CGRect.zero)
        
        self.placeholder = placeholder
        
        setUpStyle()
    }
    
    public override init(frame: CGRect) {
        preconditionFailure("Use init(placeholder:) instead.")
    }
    
    public required init?(coder: NSCoder) {
        preconditionFailure("Use init(placeholder:) instead.")
    }
    
    private func setUpStyle() {
        font = .systemFont(ofSize: Values.smallFontSize)
        themeTextColor = .textPrimary
        themeTintColor = .primary
        themeBorderColor = .borderSeparator
        themeAttributedPlaceholder = placeholder.map {
            ThemedAttributedString(
                string: $0,
                attributes: [
                    .themeForegroundColor: ThemeValue.textSecondary
                ]
            )
        }
        layer.borderWidth = 1
        layer.cornerRadius = SNTextField.cornerRadius
        
        if usesDefaultHeight {
            set(.height, to: height)
        }
        
        ThemeManager.onThemeChange(observer: self) { [weak self] theme, _ in
            self?.keyboardAppearance = theme.keyboardAppearance
        }
    }
    
    public override func textRect(forBounds bounds: CGRect) -> CGRect {
        if usesDefaultHeight {
            return bounds.insetBy(dx: horizontalInset, dy: verticalInset)
        }
        else {
            return bounds.insetBy(dx: Values.mediumSpacing, dy: Values.smallSpacing)
        }
    }
    
    public override func editingRect(forBounds bounds: CGRect) -> CGRect {
        if usesDefaultHeight {
            return bounds.insetBy(dx: horizontalInset, dy: verticalInset)
        }
        else {
            return bounds.insetBy(dx: Values.mediumSpacing, dy: Values.smallSpacing)
        }
    }
}
