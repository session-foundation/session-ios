// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Combine
import Lucide

public final class ProfilePictureView: UIView {
    private var dataManager: ImageDataManagerType?
    private var sessionProManager: SessionProUIManagerType?
    public var size: Info.Size {
        didSet {
            widthConstraint.constant = size.viewSize
            heightConstraint.constant = size.viewSize
            profileView.size = size
            additionalProfileView.size = size
            
            invalidateIntrinsicContentSize()
        }
    }
    
    public override var intrinsicContentSize: CGSize {
        CGSize(width: size.viewSize, height: size.viewSize)
    }
    
    public override var isHidden: Bool {
        didSet {
            widthConstraint.constant = (isHidden ? 0 : size.viewSize)
            heightConstraint.constant = (isHidden ? 0 : size.viewSize)
        }
    }
    
    // MARK: - Constraints
    
    private var widthConstraint: NSLayoutConstraint!
    private var heightConstraint: NSLayoutConstraint!
    private var profileViewTopConstraint: NSLayoutConstraint!
    private var profileViewLeadingConstraint: NSLayoutConstraint!
    private var profileViewCenterXConstraint: NSLayoutConstraint!
    private var profileViewCenterYConstraint: NSLayoutConstraint!
    
    // MARK: - Components
    
    private lazy var profileView: ProfileView = {
        let result: ProfileView = ProfileView(
            size: size,
            isMultiImage: false,
            dataManager: dataManager
        )
        result.translatesAutoresizingMaskIntoConstraints = false
        
        return result
    }()
    
    private lazy var additionalProfileView: ProfileView = {
        let result: ProfileView = ProfileView(
            size: size,
            isMultiImage: true,
            dataManager: dataManager
        )
        result.translatesAutoresizingMaskIntoConstraints = false
        
        return result
    }()
    
    // MARK: - Lifecycle
    
    @MainActor public init(size: Info.Size, dataManager: ImageDataManagerType?) {
        self.dataManager = dataManager
        self.size = size
        
        super.init(frame: CGRect(x: 0, y: 0, width: size.viewSize, height: size.viewSize))
        
        clipsToBounds = true
        setUpViewHierarchy()
    }
    
    public required init?(coder: NSCoder) {
        preconditionFailure("Use init(size:) instead.")
    }
    
    private func setUpViewHierarchy() {
        addSubview(profileView)
        addSubview(additionalProfileView)
        
        widthConstraint = self.set(.width, to: self.size.viewSize)
        heightConstraint = self.set(.height, to: self.size.viewSize)
            .setting(priority: .defaultHigh)
        
        profileViewTopConstraint = profileView.pin(.top, to: .top, of: self)
        profileViewLeadingConstraint = profileView.pin(.leading, to: .leading, of: self)
        profileViewCenterXConstraint = profileView
            .center(.horizontal, in: self)
            .setting(isActive: false)
        profileViewCenterYConstraint = profileView
            .center(.vertical, in: self)
            .setting(isActive: false)
        additionalProfileView.pin(.trailing, to: .trailing, of: self)
        additionalProfileView.pin(.bottom, to: .bottom, of: self)
    }
    
    // MARK: - Functions
    
    public func setDataManager(_ dataManager: ImageDataManagerType) {
        self.dataManager = dataManager
        self.profileView.setDataManager(dataManager)
        self.additionalProfileView.setDataManager(dataManager)
    }
    
    // MARK: - Content
    
    private func prepareForReuse() {
        profileView.prepareForReuse()
        additionalProfileView.prepareForReuse()
        additionalProfileView.isHidden = true
        
        profileViewTopConstraint.isActive = false
        profileViewLeadingConstraint.isActive = false
        profileViewCenterXConstraint.isActive = true
        profileViewCenterYConstraint.isActive = true
    }
    
    @MainActor public func update(
        _ info: Info,
        additionalInfo: Info? = nil
    ) {
        prepareForReuse()
        
        profileView.update(info, isMultiImage: (additionalInfo != nil))
        
        // Check if there is a second image (if not then set the size and finish)
        guard let additionalInfo: Info = additionalInfo else {
            invalidateIntrinsicContentSize()
            return
        }
        
        additionalProfileView.update(additionalInfo, isMultiImage: true)
        additionalProfileView.isHidden = false
        
        profileViewTopConstraint.isActive = true
        profileViewLeadingConstraint.isActive = true
        profileViewCenterXConstraint.isActive = false
        profileViewCenterYConstraint.isActive = false
        invalidateIntrinsicContentSize()
    }
    
    public func getTouchedView(from localPoint: CGPoint) -> UIView {
        if let result: UIView = profileView.getTouchedView(from: profileView.convert(localPoint, from: self)) {
            return result
        }
        if let result: UIView = additionalProfileView.getTouchedView(from: additionalProfileView.convert(localPoint, from: self)) {
            return result
        }
        
        return self
    }
}

// MARK: - ProfilePictureView.Info

public extension ProfilePictureView {
    struct Info: Equatable, Hashable {
        let source: ImageDataManager.DataSource?
        let canAnimate: Bool
        let renderingMode: UIImage.RenderingMode?
        let themeTintColor: ThemeValue?
        let inset: UIEdgeInsets
        let leadingIcon: ProfileIcon
        let trailingIcon: ProfileIcon
        let cropRect: CGRect?
        let backgroundColor: ThemeValue?
        let forcedBackgroundColor: ForcedThemeValue?
        
        public init(
            source: ImageDataManager.DataSource?,
            canAnimate: Bool,
            renderingMode: UIImage.RenderingMode? = nil,
            themeTintColor: ThemeValue? = nil,
            inset: UIEdgeInsets = .zero,
            leadingIcon: ProfileIcon = .none,
            trailingIcon: ProfileIcon = .none,
            cropRect: CGRect? = nil,
            backgroundColor: ThemeValue? = nil,
            forcedBackgroundColor: ForcedThemeValue? = nil
        ) {
            self.source = source
            self.canAnimate = canAnimate
            self.renderingMode = renderingMode
            self.themeTintColor = themeTintColor
            self.inset = inset
            self.leadingIcon = leadingIcon
            self.trailingIcon = trailingIcon
            self.cropRect = cropRect
            self.backgroundColor = backgroundColor
            self.forcedBackgroundColor = forcedBackgroundColor
        }
        
        public func hash(into hasher: inout Hasher) {
            source.hash(into: &hasher)
            canAnimate.hash(into: &hasher)
            renderingMode.hash(into: &hasher)
            themeTintColor.hash(into: &hasher)
            leadingIcon.hash(into: &hasher)
            trailingIcon.hash(into: &hasher)
            backgroundColor.hash(into: &hasher)
            forcedBackgroundColor.hash(into: &hasher)
        }
    }
}

// MARK: - ProfilePictureView.Info.Size

public extension ProfilePictureView.Info {
    enum Size {
        case navigation
        case message
        case list
        case hero
        case modal
        case expanded
        
        public var viewSize: CGFloat {
            switch self {
                case .navigation, .message: return 26
                case .list: return 46
                case .hero: return 110
                case .modal: return 90
                case .expanded: return 190
            }
        }
        
        public var imageSize: CGFloat {
            switch self {
                case .navigation, .message: return 26
                case .list: return 46
                case .hero: return 90
                case .modal: return 90
                case .expanded: return 190
            }
        }
        
        public var multiImageSize: CGFloat {
            switch self {
                case .navigation, .message: return 18  // Shouldn't be used
                case .list: return 32
                case .hero: return 80
                case .modal: return 90
                case .expanded: return 140
            }
        }
        
        public var defaultCommunityImageInsets: UIEdgeInsets {
            let padding: CGFloat
            
            switch self {
                case .navigation, .message: padding = 7
                case .list: padding = 12
                case .hero: padding = 28
                case .modal: padding = 24
                case .expanded: padding = 50
            }
            
            return UIEdgeInsets(
                top: padding,
                left: padding,
                bottom: padding,
                right: padding
            )
        }
        
        public var multiImagePlaceholderInsets: UIEdgeInsets {
            return UIEdgeInsets(
                top: 0,
                left: 0,
                bottom: {
                    switch self {
                        case .navigation, .message: return -4
                        case .list: return -6
                        case .hero: return -14
                        case .modal: return -13
                        case .expanded: return -28
                    }
                }(),
                right: 0
            )
        }
        
        var iconSize: CGFloat {
            switch self {
                case .navigation, .message: return 10   // Intentionally not a multiple of 4
                case .list: return 16
                case .hero: return 24
                case .modal: return 24 // Shouldn't be used
                case .expanded: return 33
            }
        }
    }
}

// MARK: - ProfilePictureView.Info.ProfileIcon

public extension ProfilePictureView.Info {
    enum ProfileIcon: Equatable, Hashable {
        case none
        case crown
        case rightPlus
        case letter(Character, Bool)
        case pencil
        case qrCode
        
        func iconVerticalInset(for size: Size) -> CGFloat {
            switch (self, size) {
                case (.crown, .navigation), (.crown, .message): return 2
                case (.crown, .list): return 3
                case (.crown, .hero): return 5
                    
                case (.rightPlus, _): return 3
                default: return 0
            }
        }
        
        var isLeadingAligned: Bool {
            switch self {
                case .none, .letter: return true
                case .rightPlus, .pencil, .crown, .qrCode: return false
            }
        }
    }
}

// MARK: - ProfilePictureView.ProfileView

private extension ProfilePictureView {
    final class ProfileView: UIView {
        private var dataManager: ImageDataManagerType?
        public var size: Info.Size {
            didSet {
                let targetSize: CGFloat = (isMultiImage ? size.multiImageSize : size.imageSize)
                widthConstraint.constant = targetSize
                heightConstraint.constant = targetSize
                borderView.layer.cornerRadius = ((targetSize + 2) / 2)
                backgroundView.layer.cornerRadius = (targetSize / 2)
                imageClippingView.layer.cornerRadius = (targetSize / 2)
                
                leadingIconView.size = size
                trailingIconView.size = size
            }
        }
        private var loadIdentifier: UUID?
        private var isMultiImage: Bool
        
        // MARK: - Constraints
        
        private var widthConstraint: NSLayoutConstraint!
        private var heightConstraint: NSLayoutConstraint!
        
        private var leadingIconTopConstraint: NSLayoutConstraint!
        private var leadingIconBottomConstraint: NSLayoutConstraint!
        private var leadingIconHorizontalConstraint: NSLayoutConstraint!
        
        private var trailingIconTopConstraint: NSLayoutConstraint!
        private var trailingIconBottomConstraint: NSLayoutConstraint!
        private var trailingIconHorizontalConstraint: NSLayoutConstraint!
        
        private lazy var imageEdgeConstraints: [NSLayoutConstraint] = [
            /// **MUST** be in 'top, left, bottom, right' order
            imageView.pin(.top, to: .top, of: imageClippingView, withInset: 0),
            imageView.pin(.left, to: .left, of: imageClippingView, withInset: 0),
            imageView.pin(.bottom, to: .bottom, of: imageClippingView, withInset: 0),
            imageView.pin(.right, to: .right, of: imageClippingView, withInset: 0)
        ]
        
        // MARK: - Components
        
        private lazy var borderView: UIView = {
            let result: UIView = UIView()
            result.translatesAutoresizingMaskIntoConstraints = false
            result.clipsToBounds = true
            result.isHidden = true
            result.themeBackgroundColor = .backgroundPrimary
            
            return result
        }()
        
        private lazy var backgroundView: UIView = {
            let result: UIView = UIView()
            result.translatesAutoresizingMaskIntoConstraints = false
            result.clipsToBounds = true
            
            return result
        }()
        
        private lazy var imageClippingView: UIView = {
            let result: UIView = UIView()
            result.translatesAutoresizingMaskIntoConstraints = false
            result.clipsToBounds = true
            
            return result
        }()
        
        private lazy var imageView: SessionImageView = {
            let result: SessionImageView = SessionImageView()
            result.translatesAutoresizingMaskIntoConstraints = false
            result.contentMode = .scaleAspectFill
            result.clipsToBounds = true
            
            if let dataManager = self.dataManager {
                result.setDataManager(dataManager)
            }
            
            return result
        }()
        
        private lazy var leadingIconView: IconView = {
            let result: IconView = IconView(size: size, dataManager: dataManager)
            result.isHidden = true
            
            return result
        }()
        
        private lazy var trailingIconView: IconView = {
            let result: IconView = IconView(size: size, dataManager: dataManager)
            result.isHidden = true
            
            return result
        }()
        
        // MARK: - Lifecycle
        
        @MainActor public init(
            size: Info.Size,
            isMultiImage: Bool,
            dataManager: ImageDataManagerType?
        ) {
            self.dataManager = dataManager
            self.size = size
            self.isMultiImage = isMultiImage
            
            super.init(frame: CGRect(x: 0, y: 0, width: size.viewSize, height: size.viewSize))
            
            setUpViewHierarchy()
        }
        
        public required init?(coder: NSCoder) {
            preconditionFailure("Use init(size:) instead.")
        }
        
        private func setUpViewHierarchy() {
            clipsToBounds = false
            
            addSubview(borderView)
            addSubview(backgroundView)
            addSubview(imageClippingView)
            addSubview(leadingIconView)
            addSubview(trailingIconView)
            
            imageClippingView.addSubview(imageView)
            
            widthConstraint = self.set(.width, to: self.size.imageSize)
            heightConstraint = self.set(.height, to: self.size.imageSize)
            borderView.pin(to: self, withInset: -1)
            backgroundView.pin(to: self)
            imageClippingView.pin(to: self)
            imageEdgeConstraints.forEach { $0.isActive = true }
            
            leadingIconTopConstraint = leadingIconView
                .pin(.top, to: .top, of: self)
                .setting(isActive: false)
            leadingIconBottomConstraint = leadingIconView
                .pin(.bottom, to: .bottom, of: self)
                .setting(isActive: false)
            leadingIconHorizontalConstraint = leadingIconView.pin(.leading, to: .leading, of: self)
            
            trailingIconTopConstraint = trailingIconView
                .pin(.top, to: .top, of: self)
                .setting(isActive: false)
            trailingIconBottomConstraint = trailingIconView
                .pin(.bottom, to: .bottom, of: self)
                .setting(isActive: false)
            trailingIconHorizontalConstraint = trailingIconView.pin(.trailing, to: .trailing, of: self)
        }
        
        // MARK: - Functions
        
        public func setDataManager(_ dataManager: ImageDataManagerType) {
            self.dataManager = dataManager
            self.imageView.setDataManager(dataManager)
        }
        // MARK: - Content
        
        fileprivate func prepareForReuse() {
            leadingIconView.prepareForReuse()
            trailingIconView.prepareForReuse()
            
            loadIdentifier = nil
            borderView.isHidden = true
            backgroundView.themeBackgroundColor = nil
            backgroundView.themeBackgroundColorForced = nil
            imageView.image = nil
            imageView.shouldAnimateImage = false
            imageEdgeConstraints.forEach { $0.constant = 0 }
        }
        
        @MainActor public func update(_ info: Info, isMultiImage: Bool) {
            prepareForReuse()
            self.loadIdentifier = UUID()
            self.isMultiImage = isMultiImage
            
            /// Populate the main imageView
            switch (info.source, info.renderingMode) {
                case (.image(_, let image), .some(let renderingMode)):
                    imageView.image = image?.withRenderingMode(renderingMode)
                    
                    switch (info.backgroundColor, info.forcedBackgroundColor) {
                        case (_, .some(let color)): backgroundView.themeBackgroundColorForced = color
                        case (.some(let color), _): backgroundView.themeBackgroundColor = color
                        default: backgroundView.themeBackgroundColor = nil
                    }
                    
                case (.some(let source), _):
                    let originalOrientation: UIImage.Orientation? = source.knownOrientation
                    
                    imageView.loadImage(source) { [weak self] buffer in
                        /// Ensure this image load is _actually_ for the current version of `info`
                        guard
                            let self,
                            loadIdentifier == self.loadIdentifier
                        else { return }
                        
                        switch (info.backgroundColor, info.forcedBackgroundColor) {
                            case (_, .some(let color)): self.backgroundView.themeBackgroundColorForced = color
                            case (.some(let color), _): self.backgroundView.themeBackgroundColor = color
                            default: self.backgroundView.themeBackgroundColor = nil
                        }
                        
                        /// Now that the image has loaded the "proper" orientation information will have been loaded which may be
                        /// different from the initial value set (because we took a fast path), in that case we need to re-apply the
                        /// `contentsRect` to ensure it renders correctly
                        guard originalOrientation != self.imageView.imageOrientationMetadata else {
                            return
                        }
                        
                        self.imageView.layer.contentsRect = self.contentsRect(
                            for: info.source,
                            cropRect: info.cropRect,
                            orientationMetadata: self.imageView.imageOrientationMetadata
                        )
                    }
                    
                default:
                    imageView.image = nil
                    
                    switch (info.backgroundColor, info.forcedBackgroundColor) {
                        case (_, .some(let color)): backgroundView.themeBackgroundColorForced = color
                        case (.some(let color), _): backgroundView.themeBackgroundColor = color
                        default: backgroundView.themeBackgroundColor = nil
                    }
            }
            
            let targetSize: CGFloat = (isMultiImage ? size.multiImageSize : size.imageSize)
            widthConstraint.constant = targetSize
            heightConstraint.constant = targetSize
            borderView.isHidden = !isMultiImage
            borderView.layer.cornerRadius = ((targetSize + 2) / 2)
            backgroundView.layer.cornerRadius = (targetSize / 2)
            imageClippingView.layer.cornerRadius = (targetSize / 2)
            imageView.contentMode = .scaleAspectFit
            imageView.shouldAnimateImage = info.canAnimate
            imageView.themeTintColor = info.themeTintColor
            imageView.layer.contentsRect = contentsRect(
                for: info.source,
                cropRect: info.cropRect,
                orientationMetadata: imageView.imageOrientationMetadata
            )
            leadingIconView.layer.cornerRadius = (size.iconSize / 2)
            trailingIconView.layer.cornerRadius = (size.iconSize / 2)
            imageEdgeConstraints.enumerated().forEach { index, constraint in
                switch index % 4 {
                    case 0: constraint.constant = info.inset.top
                    case 1: constraint.constant = info.inset.left
                    case 2: constraint.constant = -info.inset.bottom
                    case 3: constraint.constant = -info.inset.right
                    default: break
                }
            }
            
            /// Update the leading icon
            leadingIconView.update(icon: info.leadingIcon)
            leadingIconHorizontalConstraint.constant = (info.leadingIcon == .qrCode && size == .expanded ? 8 : 0)
            
            switch info.leadingIcon {
                case .none: break
                case .letter:
                    leadingIconTopConstraint.isActive = true
                    leadingIconBottomConstraint.isActive = false
                    
                case .crown, .rightPlus, .pencil, .qrCode:
                    leadingIconTopConstraint.isActive = false
                    leadingIconBottomConstraint.isActive = true
            }
            
            /// Update the trailing icon
            trailingIconView.update(icon: info.trailingIcon)
            trailingIconHorizontalConstraint.constant = (info.trailingIcon == .qrCode && size == .expanded ? -8 : 0)
            
            switch info.trailingIcon {
                case .none: break
                case .letter:
                    trailingIconTopConstraint.isActive = true
                    trailingIconBottomConstraint.isActive = false
                    
                case .crown, .rightPlus, .pencil, .qrCode:
                    trailingIconTopConstraint.isActive = false
                    trailingIconBottomConstraint.isActive = true
            }
        }
        
        private func contentsRect(
            for source: ImageDataManager.DataSource?,
            cropRect: CGRect?,
            orientationMetadata: UIImage.Orientation?
        ) -> CGRect {
            guard
                let source: ImageDataManager.DataSource = source,
                let cropRect: CGRect = cropRect
            else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
            
            /// Try to use the `orientationMetadata` stored on the `imageView` if present, falling back to the fast `knownOrientation`
            /// in the DataSource and lastly `up` if neither are present
            let targetOrientation: UIImage.Orientation = ((orientationMetadata ?? source.knownOrientation) ?? .up)
            
            switch targetOrientation {
                case .up: return cropRect
                    
                case .upMirrored:
                    return CGRect(
                        x: (1 - cropRect.maxX),
                        y: cropRect.minY,
                        width: cropRect.width,
                        height: cropRect.height
                    )
                    
                case .down:
                    return CGRect(
                        x: (1 - cropRect.maxX),
                        y: (1 - cropRect.maxY),
                        width: cropRect.width,
                        height: cropRect.height
                    )
                    
                case .downMirrored:
                    return CGRect(
                        x: cropRect.minX,
                        y: (1 - cropRect.maxY),
                        width: cropRect.width,
                        height: cropRect.height
                    )
                    
                case .left:
                    return CGRect(
                        x: (1 - cropRect.maxY),
                        y: cropRect.minX,
                        width: cropRect.height,
                        height: cropRect.width
                    )
                    
                case .leftMirrored:
                    return CGRect(
                        x: cropRect.minY,
                        y: cropRect.minX,
                        width: cropRect.height,
                        height: cropRect.width
                    )
                    
                case .right:
                    return CGRect(
                        x: cropRect.minY,
                        y: (1 - cropRect.maxX),
                        width: cropRect.height,
                        height: cropRect.width
                    )
                    
                case .rightMirrored:
                    return CGRect(
                        x: (1 - cropRect.maxY),
                        y: (1 - cropRect.maxX),
                        width: cropRect.height,
                        height: cropRect.width
                    )
                    
                @unknown default: return cropRect
            }
        }
        
        public func getTouchedView(from localPoint: CGPoint) -> UIView? {
            if leadingIconView.frame.contains(localPoint) {
                return leadingIconView
            }
            
            if trailingIconView.frame.contains(localPoint) {
                return trailingIconView
            }
            
            guard bounds.contains(localPoint) else {
                return nil
            }
            
            return self
        }
    }
}

// MARK: - ProfilePictureView.IconView

private extension ProfilePictureView {
    final class IconView: UIView {
        private var dataManager: ImageDataManagerType?
        public var size: Info.Size {
            didSet {
                widthConstraint.constant = size.iconSize
                heightConstraint.constant = size.iconSize
                self.layer.cornerRadius = (size.iconSize / 2)
                label.font = .boldSystemFont(ofSize: floor(size.iconSize * 0.75))
            }
        }
        
        // MARK: - Constraints
        
        private var widthConstraint: NSLayoutConstraint!
        private var heightConstraint: NSLayoutConstraint!
        private var iconTopConstraint: NSLayoutConstraint!
        private var iconBottomConstraint: NSLayoutConstraint!
        
        // MARK: - Components
        
        private lazy var imageView: SessionImageView = {
            let result: SessionImageView = SessionImageView()
            result.contentMode = .scaleAspectFit
            result.isHidden = true
            
            return result
        }()
        
        private lazy var label: UILabel = {
            let result: UILabel = UILabel()
            result.font = .boldSystemFont(ofSize: floor(size.iconSize * 0.75))
            result.textAlignment = .center
            result.themeTextColor = .backgroundPrimary
            result.isHidden = true
            
            return result
        }()
        
        // MARK: - Lifecycle
        
        @MainActor public init(size: Info.Size, dataManager: ImageDataManagerType?) {
            self.dataManager = dataManager
            self.size = size
            
            super.init(frame: CGRect(x: 0, y: 0, width: size.iconSize, height: size.iconSize))
            
            clipsToBounds = true
            setUpViewHierarchy()
        }
        
        public required init?(coder: NSCoder) {
            preconditionFailure("Use init(size:) instead.")
        }
        
        private func setUpViewHierarchy() {
            addSubview(imageView)
            addSubview(label)
            
            widthConstraint = self.set(.width, to: self.size.iconSize)
            heightConstraint = self.set(.height, to: self.size.iconSize)
            iconTopConstraint = imageView.pin(.top, to: .top, of: self)
            imageView.pin(.leading, to: .leading, of: self)
            imageView.pin(.trailing, to: .trailing, of: self)
            iconBottomConstraint = imageView.pin(.bottom, to: .bottom, of: self)
            label.pin(to: self)
        }
        
        // MARK: - Functions
        
        public func setDataManager(_ dataManager: ImageDataManagerType) {
            self.dataManager = dataManager
            self.imageView.setDataManager(dataManager)
        }
        
        // MARK: - Content
        
        @MainActor fileprivate func prepareForReuse() {
            isHidden = true
            imageView.image = nil
            imageView.isHidden = true
            label.isHidden = true
        }
        
        @MainActor fileprivate func update(icon: Info.ProfileIcon) {
            isHidden = (icon == .none)
            iconTopConstraint.constant = icon.iconVerticalInset(for: size)
            iconBottomConstraint.constant = -icon.iconVerticalInset(for: size)
            
            switch icon {
                case .none:
                    imageView.image = nil
                    imageView.isHidden = true
                    label.isHidden = true
                    
                case .crown:
                    imageView.image = UIImage(named: "ic_crown")?.withRenderingMode(.alwaysTemplate)
                    imageView.contentMode = .scaleAspectFit
                    imageView.themeTintColor = .dynamicForPrimary(
                        .green,
                        use: .profileIcon_greenPrimaryColor,
                        otherwise: .profileIcon
                    )
                    themeBackgroundColor = .profileIcon_background
                    imageView.isHidden = false
                    label.isHidden = true
                    
                case .rightPlus:
                    imageView.image = UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(weight: .semibold))
                    imageView.contentMode = .scaleAspectFit
                    imageView.themeTintColor = .black
                    themeBackgroundColor = .primary
                    imageView.isHidden = false
                    label.isHidden = true
                    
                case .letter(let character, let dangerMode):
                    label.themeTextColor = (dangerMode ? .textPrimary : .backgroundPrimary)
                    themeBackgroundColor = (dangerMode ? .danger : .textPrimary)
                    label.isHidden = false
                    label.text = "\(character)"
                    
                case .pencil:
                    imageView.image = Lucide.image(icon: .pencil, size: 14)?.withRenderingMode(.alwaysTemplate)
                    imageView.contentMode = .center
                    imageView.themeTintColor = .black
                    themeBackgroundColor = .primary
                    imageView.isHidden = false
                    label.isHidden = true
                    
                case .qrCode:
                    imageView.image = Lucide.image(icon: .qrCode, size: (size == .expanded ? 20 : 14))?.withRenderingMode(.alwaysTemplate)
                    imageView.contentMode = .center
                    imageView.themeTintColor = .black
                    themeBackgroundColor = .primary
                    imageView.isHidden = false
                    label.isHidden = true
            }
        }
    }
}

// MARK: - ProfilePictureSwiftUI

import SwiftUI

public struct ProfilePictureSwiftUI: UIViewRepresentable {
    public typealias UIViewType = ProfilePictureView

    var size: ProfilePictureView.Info.Size
    var info: ProfilePictureView.Info
    var additionalInfo: ProfilePictureView.Info?
    let dataManager: ImageDataManagerType
    
    public init(
        size: ProfilePictureView.Info.Size,
        info: ProfilePictureView.Info,
        additionalInfo: ProfilePictureView.Info? = nil,
        dataManager: ImageDataManagerType
    ) {
        self.size = size
        self.info = info
        self.additionalInfo = additionalInfo
        self.dataManager = dataManager
    }
    
    public func makeUIView(context: Context) -> ProfilePictureView {
        ProfilePictureView(
            size: size,
            dataManager: dataManager
        )
    }
    
    @MainActor public func updateUIView(_ profilePictureView: ProfilePictureView, context: Context) {
        profilePictureView.update(
            info,
            additionalInfo: additionalInfo
        )
    }
}
