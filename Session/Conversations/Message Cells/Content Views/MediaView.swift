// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import YYImage
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
    private let mediaCache: NSCache<NSString, AnyObject>?
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
        mediaCache: NSCache<NSString, AnyObject>? = nil,
        attachment: Attachment,
        isOutgoing: Bool,
        shouldSupressControls: Bool,
        cornerRadius: CGFloat,
        using dependencies: Dependencies
    ) {
        self.dependencies = dependencies
        self.mediaCache = mediaCache
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

    // MARK: -

    private func createContents() {
        Log.assertOnMainThread()

        guard attachment.state != .pendingDownload && attachment.state != .downloading else {
            addDownloadProgressIfNecessary()
            return
        }
        guard attachment.state != .failedDownload else {
            configure(forError: .failed)
            return
        }
        guard attachment.isValid else {
            configure(forError: .invalid)
            return
        }
        
        if attachment.isAnimated {
            configureForAnimatedImage(attachment: attachment)
        }
        else if attachment.isImage {
            configureForStillImage(attachment: attachment)
        }
        else if attachment.isVideo {
            configureForVideo(attachment: attachment)
        }
        else {
            Log.error("[MediaView] Attachment has unexpected type.")
            configure(forError: .invalid)
        }
    }
    
    private func addDownloadProgressIfNecessary() {
        guard attachment.state != .failedDownload else {
            configure(forError: .failed)
            return
        }
        guard attachment.state != .uploading && attachment.state != .uploaded else {
            // TODO: Show "restoring" indicator and possibly progress.
            configure(forError: .missing)
            return
        }
        
        themeBackgroundColor = .backgroundSecondary
        let loader = MediaLoaderView()
        addSubview(loader)
        loader.pin([ UIView.HorizontalEdge.left, UIView.VerticalEdge.bottom, UIView.HorizontalEdge.right ], to: self)
    }

    private func addUploadProgressIfNecessary(_ subview: UIView) -> Bool {
        guard isOutgoing else { return false }
        guard attachment.state != .failedUpload else {
            configure(forError: .failed)
            return false
        }
        
        // If this message was uploaded on a different device it'll now be seen as 'downloaded' (but
        // will still be outgoing - we don't want to show a loading indicator in this case)
        guard attachment.state != .uploaded && attachment.state != .downloaded else { return false }
        
        let loader = MediaLoaderView()
        addSubview(loader)
        loader.pin([ UIView.HorizontalEdge.left, UIView.VerticalEdge.bottom, UIView.HorizontalEdge.right ], to: self)
        
        return true
    }

    private func configureForAnimatedImage(attachment: Attachment) {
        let animatedImageView: YYAnimatedImageView = YYAnimatedImageView()
        // We need to specify a contentMode since the size of the image
        // might not match the aspect ratio of the view.
        animatedImageView.contentMode = MediaView.contentMode
        // Use trilinear filters for better scaling quality at
        // some performance cost.
        animatedImageView.layer.minificationFilter = .trilinear
        animatedImageView.layer.magnificationFilter = .trilinear
        animatedImageView.themeBackgroundColor = .backgroundSecondary
        animatedImageView.isHidden = !attachment.isValid
        addSubview(animatedImageView)
        animatedImageView.pin(to: self)
        _ = addUploadProgressIfNecessary(animatedImageView)

        loadBlock = { [weak self, dependencies] in
            Log.assertOnMainThread()
            
            if animatedImageView.image != nil {
                Log.error("[MediaView] Unexpectedly already loaded.")
                return
            }
            self?.tryToLoadMedia(
                loadMediaBlock: { applyMediaBlock in
                    guard attachment.isValid else {
                        self?.configure(forError: .invalid)
                        return
                    }
                    guard let filePath: String = attachment.originalFilePath(using: dependencies) else {
                        Log.error("[MediaView] Attachment stream missing original file path.")
                        self?.configure(forError: .invalid)
                        return
                    }
                    
                    applyMediaBlock(YYImage(contentsOfFile: filePath))
                },
                applyMediaBlock: { media in
                    Log.assertOnMainThread()
                    
                    guard let image: YYImage = media as? YYImage else {
                        Log.error("[MediaView] Media has unexpected type: \(type(of: media))")
                        self?.configure(forError: .invalid)
                        return
                    }
                    // FIXME: Animated images flicker when reloading the cells (even though they are in the cache)
                    animatedImageView.image = image
                },
                cacheKey: attachment.id
            )
        }
        unloadBlock = {
            Log.assertOnMainThread()

            animatedImageView.image = nil
        }
    }

    private func configureForStillImage(attachment: Attachment) {
        let stillImageView = UIImageView()
        // We need to specify a contentMode since the size of the image
        // might not match the aspect ratio of the view.
        stillImageView.contentMode = MediaView.contentMode
        // Use trilinear filters for better scaling quality at
        // some performance cost.
        stillImageView.layer.minificationFilter = .trilinear
        stillImageView.layer.magnificationFilter = .trilinear
        stillImageView.themeBackgroundColor = .backgroundSecondary
        stillImageView.isHidden = !attachment.isValid
        addSubview(stillImageView)
        stillImageView.pin(to: self)
        _ = addUploadProgressIfNecessary(stillImageView)
        
        loadBlock = { [weak self, dependencies] in
            Log.assertOnMainThread()

            if stillImageView.image != nil {
                Log.error("[MediaView] Unexpectedly already loaded.")
                return
            }
            self?.tryToLoadMedia(
                loadMediaBlock: { applyMediaBlock in
                    guard attachment.isValid else {
                        self?.configure(forError: .invalid)
                        return
                    }
                    
                    attachment.thumbnail(
                        size: .large,
                        using: dependencies,
                        success: { image, _ in applyMediaBlock(image) },
                        failure: {
                            Log.error("[MediaView] Could not load thumbnail")
                            self?.configure(forError: .invalid)
                        }
                    )
                },
                applyMediaBlock: { media in
                    Log.assertOnMainThread()
                    
                    guard let image: UIImage = media as? UIImage else {
                        Log.error("[MediaView] Media has unexpected type: \(type(of: media))")
                        self?.configure(forError: .invalid)
                        return
                    }
                    
                    stillImageView.image = image
                },
                cacheKey: attachment.id
            )
        }
        unloadBlock = {
            Log.assertOnMainThread()

            stillImageView.image = nil
        }
    }

    private func configureForVideo(attachment: Attachment) {
        let stillImageView = UIImageView()
        // We need to specify a contentMode since the size of the image
        // might not match the aspect ratio of the view.
        stillImageView.contentMode = MediaView.contentMode
        // Use trilinear filters for better scaling quality at
        // some performance cost.
        stillImageView.layer.minificationFilter = .trilinear
        stillImageView.layer.magnificationFilter = .trilinear
        stillImageView.themeBackgroundColor = .backgroundSecondary
        stillImageView.isHidden = !attachment.isValid

        addSubview(stillImageView)
        stillImageView.pin(to: self)

        if !addUploadProgressIfNecessary(stillImageView) && !shouldSupressControls {
            if let duration: TimeInterval = attachment.duration {
                let fadeView: GradientView = GradientView()
                fadeView.themeBackgroundGradient = [
                    .value(.black, alpha: 0),
                    .value(.black, alpha: 0.4)
                ]
                stillImageView.addSubview(fadeView)
                fadeView.set(.height, to: 40)
                fadeView.pin(.leading, to: .leading, of: stillImageView)
                fadeView.pin(.trailing, to: .trailing, of: stillImageView)
                fadeView.pin(.bottom, to: .bottom, of: stillImageView)
                
                let durationLabel: UILabel = UILabel()
                durationLabel.font = .systemFont(ofSize: Values.smallFontSize)
                durationLabel.text = Format.duration(duration)
                durationLabel.themeTextColor = .white
                stillImageView.addSubview(durationLabel)
                durationLabel.pin(.trailing, to: .trailing, of: stillImageView, withInset: -Values.smallSpacing)
                durationLabel.pin(.bottom, to: .bottom, of: stillImageView, withInset: -Values.smallSpacing)
            }
            
            // Add the play button above the duration label and fade
            let videoPlayIcon = UIImage(named: "CirclePlay")
            let videoPlayButton = UIImageView(image: videoPlayIcon)
            videoPlayButton.set(.width, to: 72)
            videoPlayButton.set(.height, to: 72)
            stillImageView.addSubview(videoPlayButton)
            videoPlayButton.center(in: stillImageView)
        }

        loadBlock = { [weak self, dependencies] in
            Log.assertOnMainThread()

            if stillImageView.image != nil {
                Log.error("[MediaView] Unexpectedly already loaded.")
                return
            }
            self?.tryToLoadMedia(
                loadMediaBlock: { applyMediaBlock in
                    guard attachment.isValid else {
                        self?.configure(forError: .invalid)
                        return
                    }
                    
                    attachment.thumbnail(
                        size: .medium,
                        using: dependencies,
                        success: { image, _ in applyMediaBlock(image) },
                        failure: {
                            Log.error("[MediaView] Could not load thumbnail")
                            self?.configure(forError: .invalid)
                        }
                    )
                },
                applyMediaBlock: { media in
                    Log.assertOnMainThread()

                    guard let image: UIImage = media as? UIImage else {
                        Log.error("[MediaView] Media has unexpected type: \(type(of: media))")
                        self?.configure(forError: .invalid)
                        return
                    }
                    
                    stillImageView.image = image
                },
                cacheKey: attachment.id
            )
        }
        unloadBlock = {
            Log.assertOnMainThread()

            stillImageView.image = nil
        }
    }

    private func configure(forError error: MediaError) {
        // When there is a failure in the 'loadMediaBlock' closure this can be called
        // on a background thread - rather than dispatching in every 'loadMediaBlock'
        // usage we just do so here
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.configure(forError: error)
            }
            return
        }
        
        let icon: UIImage
        
        switch error {
            case .failed:
                guard let asset = UIImage(named: "media_retry") else {
                    Log.error("[MediaView] Missing image")
                    return
                }
                icon = asset
                self.isAccessibilityElement = true
                self.accessibilityIdentifier = "Media retry"
                
            case .invalid:
                guard let asset = UIImage(named: "media_invalid") else {
                    Log.error("[MediaView] Missing image")
                    return
                }
                icon = asset
                self.isAccessibilityElement = true
                self.accessibilityIdentifier = "Media invalid"
                
            case .missing: return
        }
        
        themeBackgroundColor = .backgroundSecondary
        
        // For failed ougoing messages add an overlay to make the icon more visible
        if isOutgoing {
            let attachmentOverlayView: UIView = UIView()
            attachmentOverlayView.themeBackgroundColor = .messageBubble_overlay
            addSubview(attachmentOverlayView)
            attachmentOverlayView.pin(to: self)
        }
        
        let iconView = UIImageView(image: icon.withRenderingMode(.alwaysTemplate))
        iconView.themeTintColor = .textPrimary
        iconView.alpha = Values.mediumOpacity
        addSubview(iconView)
        iconView.center(in: self)
    }

    private func tryToLoadMedia(
        loadMediaBlock: @escaping (@escaping (AnyObject?) -> Void) -> Void,
        applyMediaBlock: @escaping (AnyObject) -> Void,
        cacheKey: String
    ) {
        // It's critical that we update loadState once
        // our load attempt is complete.
        let loadCompletion: (AnyObject?) -> Void = { [weak self] possibleMedia in
            guard self?.loadState == .loading else {
                Log.verbose("[MediaView] Skipping obsolete load.")
                return
            }
            guard let media: AnyObject = possibleMedia else {
                self?.loadState = .failed
                // TODO:
                //            [self showAttachmentErrorViewWithMediaView:mediaView];
                return
            }
            
            applyMediaBlock(media)
            
            self?.mediaCache?.setObject(media, forKey: cacheKey as NSString)
            self?.loadState = .loaded
        }

        guard loadState == .loading else {
            Log.error("[MediaView] Unexpected load state: \(loadState)")
            return
        }

        if let media: AnyObject = self.mediaCache?.object(forKey: cacheKey as NSString) {
            Log.verbose("[MediaView] media cache hit")
            
            guard Thread.isMainThread else {
                DispatchQueue.main.async {
                    loadCompletion(media)
                }
                return
            }
            
            loadCompletion(media)
            return
        }

        Log.verbose("[MediaView] media cache miss")

        MediaView.loadQueue.async { [weak self] in
            guard self?.loadState == .loading else {
                Log.verbose("[MediaView] Skipping obsolete load.")
                return
            }
            
            loadMediaBlock { media in
                guard Thread.isMainThread else {
                    DispatchQueue.main.async {
                        loadCompletion(media)
                    }
                    return
                }
                
                loadCompletion(media)
            }
        }
    }

    // We use this queue to perform the media loads.
    // These loads are expensive, so we want to:
    //
    // * Do them off the main thread.
    // * Only do one at a time.
    // * Avoid this work if possible (obsolete loads for
    //   views that are no longer visible, redundant loads
    //   of media already being loaded, don't retry media
    //   that can't be loaded, etc.).
    // * Do them in _reverse_ order. More recently enqueued
    //   loads more closely reflect the current view state.
    //   By processing in reverse order, we improve our
    //   "skip rate" of obsolete loads.
    private static let loadQueue = ReverseDispatchQueue(label: "org.signal.asyncMediaLoadQueue")

    public func loadMedia() {
        switch loadState {
            case .unloaded:
                loadState = .loading
                loadBlock?()
        
            case .loading, .loaded, .failed: break
        }
    }

    public func unloadMedia() {
        loadState = .unloaded
        unloadBlock?()
    }
}

// MARK: - SwiftUI

import SwiftUI

struct MediaView_SwiftUI: UIViewRepresentable {
    public typealias UIViewType = MediaView
    
    private let dependencies: Dependencies
    private let mediaCache: NSCache<NSString, AnyObject>?
    public let attachment: Attachment
    private let isOutgoing: Bool
    private let shouldSupressControls: Bool
    private let cornerRadius: CGFloat
    
    public init(
        mediaCache: NSCache<NSString, AnyObject>? = nil,
        attachment: Attachment,
        isOutgoing: Bool,
        shouldSupressControls: Bool,
        cornerRadius: CGFloat,
        using dependencies: Dependencies
    ) {
        self.dependencies = dependencies
        self.mediaCache = mediaCache
        self.attachment = attachment
        self.isOutgoing = isOutgoing
        self.shouldSupressControls = shouldSupressControls
        self.cornerRadius = cornerRadius
    }
    
    func makeUIView(context: Context) -> MediaView {
        let mediaView = MediaView(
            mediaCache: mediaCache,
            attachment: attachment,
            isOutgoing: isOutgoing, 
            shouldSupressControls: shouldSupressControls,
            cornerRadius: cornerRadius,
            using: dependencies
        )
        
        return mediaView
    }
    
    func updateUIView(_ mediaView: MediaView, context: Context) {
        mediaView.loadMedia()
    }
}
