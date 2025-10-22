// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit

public class SessionLabelWithProBadge: UIView {
    public var font: UIFont {
        get { label.font }
        set {
            label.font = newValue
            extraLabel.font = newValue
        }
    }
    
    public var text: String? {
        get { label.text }
        set {
            guard label.text != newValue else { return }
            label.text = newValue
        }
    }
    
    public var extraText: String? {
        get { extraLabel.text }
        set {
            guard extraLabel.text != newValue else { return }
            extraLabel.text = newValue
            extraLabel.isHidden = !(newValue?.isEmpty == false)
        }
    }
    
    public var themeAttributedText: ThemedAttributedString? {
        get { label.themeAttributedText }
        set {
            guard label.themeAttributedText != newValue else { return }
            label.themeAttributedText = newValue
        }
    }
    
    public var extraThemeAttributedText: ThemedAttributedString? {
        get { extraLabel.themeAttributedText }
        set {
            guard extraLabel.themeAttributedText != newValue else { return }
            extraLabel.themeAttributedText = newValue
        }
    }
    
    public var themeTextColor: ThemeValue? {
        get { label.themeTextColor }
        set {
            label.themeTextColor = newValue
            extraLabel.themeTextColor = newValue
        }
    }
    
    public var textAlignment: NSTextAlignment {
        get { label.textAlignment }
        set {
            label.textAlignment = newValue
            extraLabel.textAlignment = newValue
        }
    }
    
    public var lineBreakMode: NSLineBreakMode {
        get { label.lineBreakMode }
        set {
            label.lineBreakMode = newValue
            extraLabel.lineBreakMode = newValue
        }
    }
    
    public var numberOfLines: Int {
        get { label.numberOfLines }
        set {
            label.numberOfLines = newValue
            extraLabel.numberOfLines = newValue
        }
    }
    
    public var isProBadgeHidden: Bool {
        get { sessionProBadge.isHidden }
        set { sessionProBadge.isHidden = newValue }
    }
    
    public override var isUserInteractionEnabled: Bool {
        get { super.isUserInteractionEnabled }
        set {
            super.isUserInteractionEnabled = newValue
            label.isUserInteractionEnabled = newValue
            extraLabel.isUserInteractionEnabled = newValue
        }
    }
    
    private let proBadgeSize: SessionProBadge.Size
    private let proBadgeThemeBackgroundColor: ThemeValue
    private let withStretchingSpacer: Bool
    
    // MARK: - UI Components
    
    private let label: SRCopyableLabel = SRCopyableLabel()
    private let extraLabel: UILabel = UILabel()
    
    private lazy var sessionProBadge: SessionProBadge = {
        let result: SessionProBadge = SessionProBadge(size: proBadgeSize)
        result.themeBackgroundColor = proBadgeThemeBackgroundColor
        result.isHidden = true
        
        return result
    }()
    
    private lazy var stackView: UIStackView = {
        let result: UIStackView = UIStackView(
            arrangedSubviews:
                [
                    label,
                    sessionProBadge,
                    extraLabel,
                    withStretchingSpacer ? UIView.hStretchingSpacer() : nil
                ]
                .compactMap { $0 }
        )
        result.axis = .horizontal
        result.spacing = {
            switch proBadgeSize {
                case .mini: return 3
                default: return 4
            }
        }()
        result.alignment = .center
        
        return result
    }()
    
    // MARK: - Initialization
    
    public init(
        proBadgeSize: SessionProBadge.Size,
        proBadgeThemeBackgroundColor: ThemeValue = .primary,
        withStretchingSpacer: Bool = true
    ) {
        self.proBadgeSize = proBadgeSize
        self.proBadgeThemeBackgroundColor = proBadgeThemeBackgroundColor
        self.withStretchingSpacer = withStretchingSpacer
        
        super.init(frame: .zero)
        self.addSubview(stackView)
        stackView.pin(to: self)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override public func sizeThatFits(_ size: CGSize) -> CGSize {
        return label.sizeThatFits(size)
    }
}
