//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

import UIKit
import SessionUIKit
import SessionUtilitiesKit

public protocol PhotoGridItem: AnyObject {
    var isVideo: Bool { get }
    var source: ImageDataManager.DataSource { get }
}

public class PhotoGridViewCell: UICollectionViewCell {
    private static let badgeSize: CGSize = CGSize(width: 32, height: 32)
    public let imageView: SessionImageView = {
        let result: SessionImageView = SessionImageView()
        result.contentMode = .scaleAspectFill
        
        return result
    }()

    private let contentTypeBadgeView: UIImageView = {
        let result: UIImageView = UIImageView()
        result.image = UIImage(named: "ic_gallery_badge_video")
        result.isHidden = true
        
        return result
    }()
    
    private let selectedBadgeView: UIImageView = {
        let result: UIImageView = UIImageView()
        result.image = UIImage(systemName: "checkmark.circle.fill")?.withRenderingMode(.alwaysTemplate)
        result.themeTintColor = .primary
        result.themeBorderColor = .textPrimary
        result.themeBackgroundColor = .textPrimary
        result.isHidden = true
        result.layer.cornerRadius = (PhotoGridViewCell.badgeSize.width / 2)
        
        return result
    }()

    private let highlightedView: UIView = {
        let result: UIView = UIView()
        result.alpha = 0.2
        result.themeBackgroundColor = .black
        result.isHidden = true
        
        return result
    }()
    
    private let selectedView: UIView = {
        let result: UIView = UIView()
        result.alpha = 0.3
        result.themeBackgroundColor = .black
        result.isHidden = true
        
        return result
    }()

    var item: PhotoGridItem?

    private static let selectedBadgeImage = UIImage(systemName: "checkmark.circle.fill")

    override public var isSelected: Bool {
        didSet {
            self.selectedBadgeView.isHidden = !self.isSelected
            self.selectedView.isHidden = !self.isSelected
        }
    }

    override public var isHighlighted: Bool {
        didSet {
            self.highlightedView.isHidden = !self.isHighlighted
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        self.clipsToBounds = true

        self.contentView.addSubview(imageView)
        self.contentView.addSubview(contentTypeBadgeView)
        self.contentView.addSubview(highlightedView)
        self.contentView.addSubview(selectedView)
        self.contentView.addSubview(selectedBadgeView)

        imageView.pin(to: contentView)
        highlightedView.pin(to: contentView)
        selectedView.pin(to: contentView)

        // Note assets were rendered to match exactly. We don't want to re-size with
        // content mode lest they become less legible.
        contentTypeBadgeView.pin(.leading, to: .leading, of: contentView, withInset: 3)
        contentTypeBadgeView.pin(.bottom, to: .bottom, of: contentView, withInset: -3)
        contentTypeBadgeView.set(.width, to: 18)
        contentTypeBadgeView.set(.height, to: 12)

        selectedBadgeView.pin(.trailing, to: .trailing, of: contentView, withInset: -Values.verySmallSpacing)
        selectedBadgeView.pin(.bottom, to: .bottom, of: contentView, withInset: -Values.verySmallSpacing)
        selectedBadgeView.set(.width, to: PhotoGridViewCell.badgeSize.width)
        selectedBadgeView.set(.height, to: PhotoGridViewCell.badgeSize.height)
    }

    @available(*, unavailable, message: "Unimplemented")
    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func configure(item: PhotoGridItem, using dependencies: Dependencies) {
        self.item = item
        imageView.setDataManager(dependencies[singleton: .imageDataManager])
        imageView.themeBackgroundColor = .textSecondary
        imageView.loadImage(item.source) { [weak imageView] buffer in
            imageView?.themeBackgroundColor = (buffer != nil ? .clear : .textSecondary)
        }
        
        contentTypeBadgeView.isHidden = !item.isVideo
    }

    override public func prepareForReuse() {
        super.prepareForReuse()

        self.item = nil
        self.contentTypeBadgeView.isHidden = true
        self.highlightedView.isHidden = true
        self.selectedView.isHidden = true
        self.selectedBadgeView.isHidden = true
    }
}
