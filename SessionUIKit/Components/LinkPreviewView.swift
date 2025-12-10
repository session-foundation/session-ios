// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import NVActivityIndicatorView

// MARK: - LinkPreviewViewModel

public struct LinkPreviewViewModel {
    public enum State {
        case loading
        case draft
        case sent
    }
    
    public enum LoadResult {
        case success(LinkPreviewViewModel)
        case error(Error)
        case obsolete
    }
    
    public var state: State
    public var urlString: String
    public var title: String?
    public var imageSource: ImageDataManager.DataSource?
    
    public var isValid: Bool {
        let hasTitle = (title == nil || title?.isEmpty == false)
        let hasImage: Bool = (imageSource != nil)
        
        return (hasTitle || hasImage)
    }
    
    public init(
        state: State,
        urlString: String,
        title: String? = nil,
        imageSource: ImageDataManager.DataSource? = nil
    ) {
        self.state = state
        self.urlString = urlString
        self.title = title
        self.imageSource = imageSource
    }
}

// MARK: - LinkPreviewView

public final class LinkPreviewView: UIView {
    private static let loaderSize: CGFloat = 24
    private static let cancelButtonSize: CGFloat = 45
    
    private let onCancel: (() -> ())?

    // MARK: - UI
    
    private lazy var imageViewContainerWidthConstraint = imageView.set(.width, to: 100)
    private lazy var imageViewContainerHeightConstraint = imageView.set(.height, to: 100)

    // MARK: UI Components
    
    public var previewView: UIView { hStackView }

    private lazy var imageView: SessionImageView = {
        let result: SessionImageView = SessionImageView()
        result.contentMode = .scaleAspectFill
        
        return result
    }()

    private lazy var imageViewContainer: UIView = {
        let result: UIView = UIView()
        result.clipsToBounds = true
        
        return result
    }()

    private let loader: NVActivityIndicatorView = {
        let result: NVActivityIndicatorView = NVActivityIndicatorView(
            frame: CGRect.zero,
            type: .circleStrokeSpin,
            color: .black,
            padding: nil
        )
        
        ThemeManager.onThemeChange(observer: result) { [weak result] _, _, resolve in
            guard let textPrimary: UIColor = resolve(.textPrimary) else { return }
            
            result?.color = textPrimary
        }
        
        return result
    }()
    
    private lazy var titleLabelContainer: UIView = {
        let result: UIView = UIView()
        result.addSubview(titleLabel)
        titleLabel.pin(to: result, withInset: Values.mediumSpacing)
        
        return result
    }()

    private lazy var titleLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = .boldSystemFont(ofSize: Values.smallFontSize)
        result.numberOfLines = 0
        
        return result
    }()

    private lazy var hStackView: UIStackView = {
        let result: UIStackView = UIStackView(arrangedSubviews: [
            imageViewContainer,
            titleLabelContainer,
            cancelButton
        ])
        result.axis = .horizontal
        result.alignment = .center
        
        return result
    }()

    private lazy var cancelButton: UIButton = {
        let result: UIButton = UIButton(type: .custom)
        result.setImage(
            UIImage(named: "X")?
                .withRenderingMode(.alwaysTemplate),
            for: .normal
        )
        result.themeTintColor = .textPrimary
        result.set(.width, to: LinkPreviewView.cancelButtonSize)
        result.set(.height, to: LinkPreviewView.cancelButtonSize)
        result.addTarget(self, action: #selector(cancel), for: UIControl.Event.touchUpInside)
        
        return result
    }()
    
    // MARK: - Initialization
    
    public init(onCancel: (() -> ())? = nil) {
        self.onCancel = onCancel
        
        super.init(frame: CGRect.zero)
        
        setUpViewHierarchy()
    }

    override init(frame: CGRect) {
        self.onCancel = nil
        
        super.init(frame: CGRect.zero)
        
        setUpViewHierarchy()
    }

    required init?(coder: NSCoder) {
        preconditionFailure("Use init(for:onCancel:) instead.")
    }

    private func setUpViewHierarchy() {
        // Image view
        imageViewContainerWidthConstraint.isActive = true
        imageViewContainerHeightConstraint.isActive = true
        imageViewContainer.addSubview(imageView)
        imageView.pin(to: imageViewContainer)
        
        // Horizontal stack view
        addSubview(hStackView)
        hStackView.pin(to: self)
        
        // Loader
        addSubview(loader)
        
        let loaderSize = LinkPreviewView.loaderSize
        loader.set(.width, to: loaderSize)
        loader.set(.height, to: loaderSize)
        loader.center(in: self)
    }

    // MARK: - Updating
    
    @MainActor public func update(
        with viewModel: LinkPreviewViewModel,
        isOutgoing: Bool,
        dataManager: ImageDataManagerType
    ) {
        // Image view
        let imageViewContainerSize: CGFloat = (viewModel.state == .sent ? 100 : 80)
        imageViewContainerWidthConstraint.constant = imageViewContainerSize
        imageViewContainerHeightConstraint.constant = imageViewContainerSize
        imageViewContainer.layer.cornerRadius = (viewModel.state == .sent ? 0 : 8)
        imageView.themeTintColor = (isOutgoing ?
            .messageBubble_outgoingText :
            .messageBubble_incomingText
        )
        
        // Title
        titleLabel.text = viewModel.title
        titleLabel.themeTextColor = (isOutgoing ?
            .messageBubble_outgoingText :
            .messageBubble_incomingText
        )
        
        let imageContentExists: Bool = (viewModel.imageSource?.contentExists == true)
        let imageSource: ImageDataManager.DataSource = {
            guard
                let source: ImageDataManager.DataSource = viewModel.imageSource,
                source.contentExists
            else { return .icon(.link, size: 32, renderingMode: .alwaysTemplate) }
                
            return source
        }()
        
        loader.alpha = (viewModel.state == .loading ? 1 : 0)
        imageView.setDataManager(dataManager)
        imageView.contentMode = (imageContentExists ? .scaleAspectFill : .center)
        cancelButton.isHidden = (viewModel.state != .draft)
        
        switch viewModel.state {
            case .loading:
                loader.startAnimating()
                imageView.image = nil
                themeBackgroundColor = nil
                imageViewContainer.themeBackgroundColor = .clear
                
            case .sent:
                loader.stopAnimating()
                imageView.loadImage(imageSource)
                themeBackgroundColor = .messageBubble_overlay
                imageViewContainer.themeBackgroundColor = .messageBubble_overlay
                
            case .draft:
                loader.stopAnimating()
                imageView.loadImage(imageSource)
                themeBackgroundColor = nil
                imageViewContainer.themeBackgroundColor = .messageBubble_overlay
        }
    }

    // MARK: - Interaction
    
    @objc private func cancel() {
        onCancel?()
    }
}
