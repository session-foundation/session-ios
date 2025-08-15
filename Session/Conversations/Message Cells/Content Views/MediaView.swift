// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionMessagingKit
import SignalUtilitiesKit
import SessionUtilitiesKit

public class MediaView: UIView {
    static let contentMode: UIView.ContentMode = .scaleAspectFill
    
    private enum MediaError {
        case missing
        case invalid
        case failed
    }

    // MARK: -

    private let dependencies: Dependencies
    public let attachment: Attachment
    private let isOutgoing: Bool
    private let shouldSupressControls: Bool
    private var loadBlock: (() -> Void)?
    private var unloadBlock: (() -> Void)?

    // MARK: - LoadState

    // The loadState property allows us to:
    //
    // * Make sure we only have one load attempt
    //   enqueued at a time for a given piece of media.
    // * We never retry media that can't be loaded.
    // * We skip media loads which are no longer
    //   necessary by the time they reach the front
    //   of the queue.

    enum LoadState: ThreadSafeType {
        case unloaded
        case loading
        case loaded
        case failed
    }

    @ThreadSafe private var loadState: LoadState = .unloaded

    // MARK: - Initializers

    public required init(
        attachment: Attachment,
        isOutgoing: Bool,
        shouldSupressControls: Bool,
        cornerRadius: CGFloat,
        using dependencies: Dependencies
    ) {
        self.dependencies = dependencies
        self.attachment = attachment
        self.isOutgoing = isOutgoing
        self.shouldSupressControls = shouldSupressControls

        super.init(frame: .zero)

        themeBackgroundColor = .backgroundSecondary
        clipsToBounds = true
        layer.masksToBounds = true
        layer.cornerRadius = cornerRadius

        createContents()
    }

    @available(*, unavailable, message: "use other init() instead.")
    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        loadState = .unloaded
    }
    
    // MARK: - UI
    
    public lazy var imageView: SessionImageView = {
        let result: SessionImageView = SessionImageView(
            dataManager: dependencies[singleton: .imageDataManager]
        )
        // We need to specify a contentMode since the size of the image
        // might not match the aspect ratio of the view.
        result.contentMode = MediaView.contentMode
        // Use trilinear filters for better scaling quality at
        // some performance cost.
        result.layer.minificationFilter = .trilinear
        result.layer.magnificationFilter = .trilinear
        result.themeBackgroundColor = .backgroundSecondary
        result.isHidden = !attachment.isValid
        
        return result
    }()
    
    private lazy var overlayView: UIView = {
        let result: UIView = UIView()
        result.themeBackgroundColor = .messageBubble_overlay
        result.isHidden = !isOutgoing
        
        return result
    }()
    
    private lazy var errorIconView: UIImageView = {
        let result: UIImageView = UIImageView()
        result.themeTintColor = .textPrimary
        result.alpha = Values.mediumOpacity
        result.isHidden = true
        
        return result
    }()
    
    private lazy var durationBackgroundView: GradientView = {
        let result: GradientView = GradientView()
        result.themeBackgroundGradient = [
            .value(.black, alpha: 0),
            .value(.black, alpha: 0.4)
        ]
        result.isHidden = true
        
        return result
    }()
    
    private lazy var durationLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = .systemFont(ofSize: Values.smallFontSize)
        result.text = attachment.duration.map { Format.duration($0) }
        result.themeTextColor = .white
        result.isHidden = true
        
        return result
    }()
    
    private lazy var playButtonIcon: UIImageView = {
        let result: UIImageView = UIImageView(image: UIImage(named: "CirclePlay"))
        result.isHidden = true
        
        return result
    }()
    
    private let loadingIndicator: MediaLoaderView = {
        let result: MediaLoaderView = MediaLoaderView()
        result.isHidden = true
        
        return result
    }()

    // MARK: -

    @MainActor
    private func createContents() {
        addSubview(imageView)
        imageView.pin(to: self)
        
        addSubview(overlayView)
        overlayView.pin(to: self)
        
        addSubview(errorIconView)
        errorIconView.center(in: self)
        
        addSubview(durationBackgroundView)
        durationBackgroundView.set(.height, to: 40)
        durationBackgroundView.pin(.leading, to: .leading, of: imageView)
        durationBackgroundView.pin(.trailing, to: .trailing, of: imageView)
        durationBackgroundView.pin(.bottom, to: .bottom, of: imageView)
        
        addSubview(durationLabel)
        durationLabel.pin(.trailing, to: .trailing, of: imageView, withInset: -Values.smallSpacing)
        durationLabel.pin(.bottom, to: .bottom, of: imageView, withInset: -Values.smallSpacing)
        
        addSubview(playButtonIcon)
        playButtonIcon.set(.width, to: 72)
        playButtonIcon.set(.height, to: 72)
        playButtonIcon.center(in: self)
        
        addSubview(loadingIndicator)
        loadingIndicator.pin(.leading, to: .leading, of: self)
        loadingIndicator.pin(.trailing, to: .trailing, of: self)
        loadingIndicator.pin(.bottom, to: .bottom, of: self)
        
        /// Load in image data if possible
        switch (attachment.state, attachment.isValid, attachment.isVisualMedia) {
            case (.pendingDownload, _, _), (.downloading, _, _):
                loadingIndicator.isHidden = false
                themeBackgroundColor = .backgroundSecondary
            
            case (.failedDownload, _, _): return configure(forError: .failed)
                
            /// This **must** come after the `pendingDownload`/`downloading` since `isValid` will be `false` until
            /// an image has been downloaded
            case (_, false, _), (_, _, false): return configure(forError: .invalid)
            
            case (_, true, true):
                imageView.loadThumbnail(size: .medium, attachment: attachment, using: dependencies) { [weak self] processedData in
                    guard processedData == nil else { return }
                    
                    Log.error("[MediaView] Could not load thumbnail")
                    Task { @MainActor [weak self] in self?.configure(forError: .invalid) }
                }
        }
        
        /// For files which are being uploaded we also want to show the `loadingIndicator` (or an error), the main difference with
        /// the above cases is that these would appear on top of any image data
        switch (isOutgoing, attachment.state) {
            case (false, _), (_, .uploaded), (_, .downloaded): break
            case (true, .failedUpload): configure(forError: .failed)
            case (true, _): loadingIndicator.isHidden = false
        }
        
        /// Show the controls if needed
        playButtonIcon.isHidden = (
            !loadingIndicator.isHidden ||
            !attachment.isVideo
        )
        durationLabel.isHidden = (
            shouldSupressControls ||
            attachment.duration == nil ||
            !loadingIndicator.isHidden ||
            !attachment.isVideo
        )
        durationBackgroundView.isHidden = durationLabel.isHidden
    }

    @MainActor
    private func configure(forError error: MediaError) {
        switch error {
            case .failed:
                errorIconView.image = UIImage(named: "media_retry")?
                    .withRenderingMode(.alwaysTemplate)
                errorIconView.isHidden = false
                self.isAccessibilityElement = true
                self.accessibilityIdentifier = "Media retry"
                
            case .invalid:
                errorIconView.image = UIImage(named: "media_invalid")?
                    .withRenderingMode(.alwaysTemplate)
                errorIconView.isHidden = false
                self.isAccessibilityElement = true
                self.accessibilityIdentifier = "Media invalid"
                
            case .missing: return
        }
        
        themeBackgroundColor = .backgroundSecondary
    }
}

// MARK: - SwiftUI

import SwiftUI

struct MediaView_SwiftUI: UIViewRepresentable {
    public typealias UIViewType = MediaView
    
    private let dependencies: Dependencies
    public let attachment: Attachment
    private let isOutgoing: Bool
    private let shouldSupressControls: Bool
    private let cornerRadius: CGFloat
    
    public init(
        attachment: Attachment,
        isOutgoing: Bool,
        shouldSupressControls: Bool,
        cornerRadius: CGFloat,
        using dependencies: Dependencies
    ) {
        self.dependencies = dependencies
        self.attachment = attachment
        self.isOutgoing = isOutgoing
        self.shouldSupressControls = shouldSupressControls
        self.cornerRadius = cornerRadius
    }
    
    func makeUIView(context: Context) -> MediaView {
        let mediaView = MediaView(
            attachment: attachment,
            isOutgoing: isOutgoing, 
            shouldSupressControls: shouldSupressControls,
            cornerRadius: cornerRadius,
            using: dependencies
        )
        
        return mediaView
    }
    
    func updateUIView(_ mediaView: MediaView, context: Context) {}
}
