// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import AVKit
import AVFoundation
import SessionUIKit
import SignalUtilitiesKit
import SessionMessagingKit
import SessionUtilitiesKit

public enum MediaGalleryOption {
    case sliderEnabled
    case showAllMediaButton
}

class MediaDetailViewController: OWSViewController, UIScrollViewDelegate {
    private let dependencies: Dependencies
    public let galleryItem: MediaGalleryViewModel.Item
    public weak var delegate: MediaDetailViewControllerDelegate?
    
    // MARK: - UI
    
    private lazy var scrollView: UIScrollView = {
        let result: UIScrollView = UIScrollView()
        result.showsVerticalScrollIndicator = false
        result.showsHorizontalScrollIndicator = false
        result.contentInsetAdjustmentBehavior = .never
        result.decelerationRate = .fast
        result.minimumZoomScale = 1
        result.maximumZoomScale = 10
        result.zoomScale = 1
        result.delegate = self
        
        return result
    }()
    
    public lazy var mediaView: SessionImageView = {
        let result: SessionImageView = SessionImageView(
            dataManager: dependencies[singleton: .imageDataManager]
        )
        result.translatesAutoresizingMaskIntoConstraints = false
        result.clipsToBounds = true
        result.contentMode = .scaleAspectFit
        result.isUserInteractionEnabled = true
        result.layer.allowsEdgeAntialiasing = true
        result.themeBackgroundColor = .newConversation_background
        
        // Use trilinear filters for better scaling quality at
        // some performance cost.
        result.layer.minificationFilter = .trilinear
        result.layer.magnificationFilter = .trilinear
        
        // We add these gestures to mediaView rather than
        // the root view so that interacting with the video player
        // progres bar doesn't trigger any of these gestures.
        let doubleTap: UITapGestureRecognizer = UITapGestureRecognizer(
            target: self,
            action: #selector(didDoubleTapImage(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        result.addGestureRecognizer(doubleTap)

        let singleTap: UITapGestureRecognizer = UITapGestureRecognizer(
            target: self,
            action: #selector(didSingleTapImage(_:))
        )
        singleTap.require(toFail: doubleTap)
        result.addGestureRecognizer(singleTap)
        
        return result
    }()
    
    private lazy var playVideoButton: UIButton = {
        let result: UIButton = UIButton()
        result.contentMode = .scaleAspectFill
        result.setBackgroundImage(UIImage(named: "CirclePlay"), for: .normal)
        result.addTarget(self, action: #selector(playVideo), for: .touchUpInside)
        result.alpha = 0
        
        let playButtonSize: CGFloat = Values.scaleFromIPhone5(70)
        result.set(.width, to: playButtonSize)
        result.set(.height, to: playButtonSize)
        
        return result
    }()
    
    // MARK: - Initialization
    
    init(
        galleryItem: MediaGalleryViewModel.Item,
        delegate: MediaDetailViewControllerDelegate? = nil,
        using dependencies: Dependencies
    ) {
        self.dependencies = dependencies
        self.galleryItem = galleryItem
        self.delegate = delegate
        
        super.init(nibName: nil, bundle: nil)
        
        mediaView.loadImage(attachment: galleryItem.attachment, using: dependencies)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        self.view.themeBackgroundColor = .newConversation_background
        
        self.view.addSubview(scrollView)
        self.view.addSubview(playVideoButton)
        scrollView.addSubview(mediaView)
        
        scrollView.pin(to: self.view)
        playVideoButton.center(in: self.view)
        mediaView.center(in: scrollView)
        mediaView.pin(.leading, to: .leading, of: scrollView.contentLayoutGuide)
        mediaView.pin(.top, to: .top, of: scrollView.contentLayoutGuide)
        mediaView.pin(.trailing, to: .trailing, of: scrollView.contentLayoutGuide)
        mediaView.pin(.bottom, to: .bottom, of: scrollView.contentLayoutGuide)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        if self.parent == nil || !(self.parent is MediaPageViewController) {
            parentDidAppear()
        }
    }
    
    public func parentDidAppear() {
        mediaView.startAnimationLoop()
        
        if self.galleryItem.attachment.isVideo {
            UIView.animate(withDuration: 0.2) { self.playVideoButton.alpha = 1 }
        }
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        
        self.centerContentIfNeeded()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        UIView.animate(withDuration: 0.15) { [weak playVideoButton] in playVideoButton?.alpha = 0 }
    }
    
    // MARK: - Functions
    
    public func zoomOut(animated: Bool) {
        if self.scrollView.zoomScale != self.scrollView.minimumZoomScale {
            self.scrollView.setZoomScale(self.scrollView.minimumZoomScale, animated: animated)
        }
    }

    // MARK: - Gesture Recognizers

    @objc private func didSingleTapImage(_ gesture: UITapGestureRecognizer) {
        self.delegate?.mediaDetailViewControllerDidTapMedia(self)
    }

    @objc private func didDoubleTapImage(_ gesture: UITapGestureRecognizer) {
        guard self.scrollView.zoomScale == self.scrollView.minimumZoomScale else {
            // If already zoomed in at all, zoom out all the way.
            self.zoomOut(animated: true)
            return
        }
        
        let doubleTapZoomScale: CGFloat = 4
        let zoomWidth: CGFloat = (self.scrollView.bounds.width / doubleTapZoomScale)
        let zoomHeight: CGFloat = (self.scrollView.bounds.height / doubleTapZoomScale)

        // Center zoom rect around tapLocation
        let tapLocation: CGPoint = gesture.location(in: self.mediaView)
        let zoomX: CGFloat = max(0, tapLocation.x - zoomWidth / 2)
        let zoomY: CGFloat = max(0, tapLocation.y - zoomHeight / 2)
        let zoomRect: CGRect = CGRect(x: zoomX, y: zoomY, width: zoomWidth, height: zoomHeight)
        let translatedRect: CGRect = self.mediaView.convert(zoomRect, to: self.scrollView)
        
        self.scrollView.zoom(to: translatedRect, animated: true)
    }

    public func didPressPlayBarButton() {
        self.playVideo()
    }

    // MARK: - UIScrollViewDelegate
    
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        return self.mediaView
    }
    
    private func centerContentIfNeeded() {
        let scrollViewSize: CGSize = self.scrollView.bounds.size
        let imageViewSize: CGSize = self.mediaView.frame.size
        
        guard
            scrollViewSize.width > 0 &&
            scrollViewSize.height > 0 &&
            imageViewSize.width > 0 &&
            imageViewSize.height > 0
        else { return }
        
        var topInset: CGFloat = 0
        var leftInset: CGFloat = 0

        if imageViewSize.height < scrollViewSize.height {
            topInset = (scrollViewSize.height - imageViewSize.height) / 2.0
        }
        if imageViewSize.width < scrollViewSize.width {
            leftInset = (scrollViewSize.width - imageViewSize.width) / 2.0
        }

        topInset = max(0, topInset)
        leftInset = max(0, leftInset)
        
        scrollView.contentInset = UIEdgeInsets(top: topInset, left: leftInset, bottom: 0, right: 0)
    }
    
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        self.centerContentIfNeeded()
        self.view.layoutIfNeeded()
    }

    // MARK: - Video Playback

    @objc public func playVideo() {
        guard
            let path: String = try? dependencies[singleton: .attachmentManager].createTemporaryFileForOpening(
                downloadUrl: self.galleryItem.attachment.downloadUrl,
                mimeType: self.galleryItem.attachment.contentType,
                sourceFilename: self.galleryItem.attachment.sourceFilename
            ),
            dependencies[singleton: .fileManager].fileExists(atPath: path)
        else { return Log.error(.media, "Missing video file") }
        
        let videoUrl: URL = URL(fileURLWithPath: path)
        let player: AVPlayer = AVPlayer(url: videoUrl)
        let viewController: DismissCallbackAVPlayerViewController = DismissCallbackAVPlayerViewController { [dependencies] in
            /// Sanity check to make sure we don't unintentionally remove a proper attachment file
            guard path.hasPrefix(dependencies[singleton: .fileManager].temporaryDirectory) else {
                return
            }
            
            try? dependencies[singleton: .fileManager].removeItem(atPath: path)
        }
        viewController.player = player
        self.present(viewController, animated: true) { [weak player] in
            player?.play()
        }
    }
}

// MARK: - MediaDetailViewControllerDelegate

protocol MediaDetailViewControllerDelegate: AnyObject {
    func mediaDetailViewControllerDidTapMedia(_ mediaDetailViewController: MediaDetailViewController)
}
