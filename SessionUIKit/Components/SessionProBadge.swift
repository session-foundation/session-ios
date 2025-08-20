// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit

public class SessionProBadge: UIView {
    public enum Size {
        case mini, small, medium, large
        
        var width: CGFloat {
            switch self {
                case .mini: return 24
                case .small: return 32
                case .medium: return 40
                case .large: return 52
            }
        }
        var height: CGFloat {
            switch self {
                case .mini: return 11
                case .small: return 14.5
                case .medium: return 18
                case .large: return 26
            }
        }
        var cornerRadius: CGFloat {
            switch self {
                case .mini: return 2.5
                case .small: return 3.5
                case .medium: return 4
                case .large: return 6
            }
        }
        var proFontHeight: CGFloat {
            switch self {
                case .mini: return 5
                case .small: return 6
                case .medium: return 7
                case .large: return 11
            }
        }
        var proFontWidth: CGFloat {
            switch self {
                case .mini: return 17
                case .small: return 24
                case .medium: return 28
                case .large: return 40
            }
        }
    }
    
    public var size: Size {
        didSet {
            widthConstraint.constant = size.width
            heightConstraint.constant = size.height
            proImageWidthConstraint.constant = size.proFontWidth
            proImageHeightConstraint.constant = size.proFontHeight
            self.layer.cornerRadius = size.cornerRadius
        }
    }
    
    // MARK: -  Initialization
    
    public init(size: Size = .small) {
        self.size = size
        super.init(frame: .zero)
        setUpViewHierarchy()
    }
    
    public override init(frame: CGRect) {
        preconditionFailure("Use init(size:) instead.")
    }
    
    public required init?(coder: NSCoder) {
        preconditionFailure("Use init(size:) instead.")
    }
    
    // MARK: - UI
    
    private lazy var proImageView: UIImageView = {
        let result: UIImageView = UIImageView(image: UIImage(named: "session_pro"))
        result.contentMode = .scaleAspectFit
        
        return result
    }()
    
    private var widthConstraint: NSLayoutConstraint!
    private var heightConstraint: NSLayoutConstraint!
    private var proImageWidthConstraint: NSLayoutConstraint!
    private var proImageHeightConstraint: NSLayoutConstraint!
    
    private func setUpViewHierarchy() {
        self.addSubview(proImageView)
        proImageWidthConstraint = proImageView.set(.height, to: self.size.proFontHeight)
        proImageHeightConstraint = proImageView.set(.width, to: self.size.proFontWidth)
        proImageView.center(in: self)
        
        self.themeBackgroundColor = .primary
        self.clipsToBounds = true
        self.layer.cornerRadius = self.size.cornerRadius
        widthConstraint = self.set(.width, to: self.size.width)
        heightConstraint = self.set(.height, to: self.size.height)
    }
}
