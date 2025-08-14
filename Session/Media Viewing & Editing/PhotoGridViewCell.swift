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
    public let imageView: SessionImageView

    private let contentTypeBadgeView: UIImageView
    private let selectedBadgeView: UIImageView

    private let highlightedView: UIView
    private let selectedView: UIView

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
        self.imageView = SessionImageView()
        imageView.contentMode = .scaleAspectFill

        self.contentTypeBadgeView = UIImageView()
        contentTypeBadgeView.isHidden = true

        let kSelectedBadgeSize = CGSize(width: 32, height: 32)
        self.selectedBadgeView = UIImageView()
        selectedBadgeView.image = UIImage(named: "ic_gallery_badge_video")?.withRenderingMode(.alwaysTemplate)
        selectedBadgeView.themeTintColor = .primary
        selectedBadgeView.themeBorderColor = .textPrimary
        selectedBadgeView.themeBackgroundColor = .textPrimary
        selectedBadgeView.isHidden = true
        selectedBadgeView.layer.cornerRadius = (kSelectedBadgeSize.width / 2)

        self.highlightedView = UIView()
        highlightedView.alpha = 0.2
        highlightedView.themeBackgroundColor = .black
        highlightedView.isHidden = true

        self.selectedView = UIView()
        selectedView.alpha = 0.3
        selectedView.themeBackgroundColor = .black
        selectedView.isHidden = true

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
        selectedBadgeView.set(.width, to: kSelectedBadgeSize.width)
        selectedBadgeView.set(.height, to: kSelectedBadgeSize.height)
    }

    @available(*, unavailable, message: "Unimplemented")
    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func configure(item: PhotoGridItem, using dependencies: Dependencies) {
        self.item = item
        imageView.setDataManager(dependencies[singleton: .imageDataManager])
        imageView.themeBackgroundColor = .textSecondary
        imageView.loadImage(item.source) { [weak imageView] processedData in
            imageView?.themeBackgroundColor = (processedData != nil ? .clear : .textSecondary)
        }
        
        contentTypeBadgeView.isHidden = !item.isVideo
    }

    override public func prepareForReuse() {
        super.prepareForReuse()

        self.item = nil
        self.imageView.image = nil
        self.contentTypeBadgeView.isHidden = true
        self.highlightedView.isHidden = true
        self.selectedView.isHidden = true
        self.selectedBadgeView.isHidden = true
    }
}
