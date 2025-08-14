// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit

public class SessionProBadge: UIView {
    public enum Size {
        case mini, small, large
        
        var width: CGFloat {
            switch self {
                case .mini: return 24
                case .small: return 40
                case .large: return 52
            }
        }
        var height: CGFloat {
            switch self {
                case .mini: return 11
                case .small: return 18
                case .large: return 26
            }
        }
        var cornerRadius: CGFloat {
            switch self {
                case .mini: return 3
                case .small: return 4
                case .large: return 6
            }
        }
        var proFontHeight: CGFloat {
            switch self {
                case .mini: return 5
                case .small: return 7
                case .large: return 11
            }
        }
        var proFontWidth: CGFloat {
            switch self {
                case .mini: return 18
                case .small: return 28
                case .large: return 40
            }
        }
    }
    
    private let size: Size
    
    // MARK: -  Initialization
    
    public init(size: Size, themeBackgroundColor: ThemeValue = .primary) {
        self.size = size
        super.init(frame: .zero)
        self.setupView(themeBackgroundColor)
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
    
    private func setupView(_ themeBackgroundColor: ThemeValue) {
        self.addSubview(proImageView)
        proImageView.set(.height, to: self.size.proFontHeight)
        proImageView.set(.width, to: self.size.proFontWidth)
        proImageView.center(in: self)
        
        self.themeBackgroundColor = themeBackgroundColor
        self.clipsToBounds = true
        self.layer.cornerRadius = self.size.cornerRadius
        self.set(.width, to: self.size.width)
        self.set(.height, to: self.size.height)
    }
}
