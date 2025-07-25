// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import ImageIO

public class SessionImageView: UIImageView {
    private var dataManager: ImageDataManagerType?
    
    private var currentLoadIdentifier: String?
    private var imageLoadTask: Task<Void, Never>?
    
    private var displayLink: CADisplayLink?
    private var animationFrames: [UIImage]?
    private var animationFrameDurations: [TimeInterval]?
    private var currentFrameIndex: Int = 0
    private var accumulatedTime: TimeInterval = 0
    
    public var imageSizeMetadata: CGSize?
    
    public override var image: UIImage? {
        didSet {
            /// If we set an image directly then it'll be a static image so we should stop the animation loop and remove
            /// any animation data
            imageLoadTask?.cancel()
            stopAnimationLoop()
            currentLoadIdentifier = nil
            animationFrames = nil
            animationFrameDurations = nil
            currentFrameIndex = 0
            accumulatedTime = 0
            imageSizeMetadata = nil
        }
    }
    
    // MARK: - Initialization
    
    /// Use the `init(dataManager:)` initializer where possible to avoid explicitly needing to add the `dataManager` instance
    public init() {
        self.dataManager = nil
        
        super.init(frame: .zero)
    }
    
    public init(dataManager: ImageDataManagerType) {
        self.dataManager = dataManager
        
        super.init(frame: .zero)
    }
    
    public init(frame: CGRect, dataManager: ImageDataManagerType) {
        self.dataManager = dataManager
        
        super.init(frame: frame)
    }
    
    public init(image: UIImage?, dataManager: ImageDataManagerType) {
        self.dataManager = dataManager
        
        /// If we are given a `UIImage` directly then it's a static image so just use it directly and don't worry about using `dataManager`
        super.init(image: image)
    }
    
    public override init(frame: CGRect) {
        fatalError("Use init(frame:dataManager:) instead")
    }
    
    public override init(image: UIImage?) {
        fatalError("Use init(image:dataManager:) instead")
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override init(image: UIImage?, highlightedImage: UIImage?) {
        fatalError("init(image:highlightedImage:) has not been implemented")
    }
    
    deinit {
        imageLoadTask?.cancel()
        
        /// The documentation for `CADisplayLink` states:
        /// ```
        /// You must call the invalidate() method when you are finished with the display link to remove it from the run loop and to free system resources.
        /// ```
        ///
        /// Since `displayLink` is added to `.main` we should invalidate it on the main thread just in case `deinit` is
        /// called elsewhere
        ///
        /// **Note:** Actor calls from `deinit` are not allowed which is why we need to do it this way (we capture `displayLink`
        /// directly because `self` could be out of scope by the time the closure is run, but `displayLink` would also be retained
        /// by the main run loop)
        if let displayLink: CADisplayLink = displayLink {
            DispatchQueue.main.async {
                displayLink.invalidate()
            }
        }
    }
    
    // MARK: - Lifecycle
    
    public override func didMoveToWindow() {
        super.didMoveToWindow()
        
        switch window {
            case .none: pauseAnimationLoop() /// Pause when not visible
            case .some:
                /// Resume only if it has animation data and was meant to be animating
                if let frames = animationFrames, frames.count > 1 {
                    resumeAnimationLoop()
                }
        }
    }
    
    // MARK: - Functions
    
    public func isAnimating() -> Bool {
        return displayLink != nil && !(displayLink?.isPaused ?? true)
    }
    
    @MainActor
    public func setDataManager(_ dataManager: ImageDataManagerType) {
        self.dataManager = dataManager
    }
    
    @MainActor
    public func loadImage(identifier: String? = nil, from path: String, onComplete: (() -> Void)? = nil) {
        /// Call through to the `url` loader so that the identifier would match regardless of whether the called used `path` or `url`
        loadImage(identifier: identifier, from: URL(fileURLWithPath: path), onComplete: onComplete)
    }
    
    @MainActor
    public func loadImage(identifier: String? = nil, from url: URL, onComplete: (() -> Void)? = nil) {
        loadImage(identifier: (identifier ?? url.absoluteString), source: .url(url), onComplete: onComplete)
    }
    
    @MainActor
    public func loadImage(identifier: String, from data: Data, onComplete: (() -> Void)? = nil) {
        loadImage(identifier: identifier, source: .data(data), onComplete: onComplete)
    }
    
    @MainActor
    public func loadImage(identifier: String, from closure: @Sendable @escaping () -> Data?, onComplete: (() -> Void)? = nil) {
        loadImage(identifier: identifier, source: .closure(closure), onComplete: onComplete)
    }
    
    @MainActor
    public func loadImage(identifier: String, from source: ImageDataManager.DataSource, onComplete: (() -> Void)? = nil) {
        loadImage(identifier: identifier, source: source, onComplete: onComplete)
    }
    
    @MainActor
    public func startAnimationLoop() {
        guard
            let frames: [UIImage] = animationFrames,
            let durations: [TimeInterval] = animationFrameDurations,
            frames.count > 1,
            frames.count == durations.count
        else { return stopAnimationLoop() }
        
        /// If it's already running (or paused) then no need to start the animation loop
        guard displayLink == nil else {
            displayLink?.isPaused = false
            return
        }
        
        /// Just to be safe set the initial frame
        if self.image == nil, frames.indices.contains(0) {
            self.image = frames[0]
        }
        
        currentFrameIndex = 0
        accumulatedTime = 0

        displayLink = CADisplayLink(target: self, selector: #selector(updateFrame))
        displayLink?.add(to: .main, forMode: .common)
    }
    
    @MainActor
    public func stopAnimationLoop() {
        displayLink?.invalidate()
        displayLink = nil
    }
    
    @MainActor
    public func pauseAnimationLoop() {
        displayLink?.isPaused = true
    }
    
    @MainActor
    public func resumeAnimationLoop() {
        /// If we don't have a `displayLink` then just start the animation
        guard displayLink != nil else {
            return startAnimationLoop()
        }
        
        displayLink?.isPaused = false
    }
    
    // MARK: - Internal Functions
    
    @MainActor
    private func loadImage(
        identifier: String,
        source: ImageDataManager.DataSource,
        onComplete: (() -> Void)?
    ) {
        /// If we are trying to load the image that is already displayed then no need to do anything
        if currentLoadIdentifier == identifier && (self.image == nil || isAnimating()) {
            /// If it was an animation that got paused then resume it
            if let frames: [UIImage] = animationFrames, !frames.isEmpty, !isAnimating() {
                startAnimationLoop()
            }
            return
        }
        
        imageLoadTask?.cancel()
        resetState(identifier: identifier)
        
        /// No need to kick of an async task if we were given an image directly
        switch source {
            case .image(_, .some(let image)):
                imageSizeMetadata = image.size
                return handleLoadedImageData(
                    ImageDataManager.ProcessedImageData(type: .staticImage(image))
                )
            
            default: break
        }
        
        /// Otherwise read the size of the image from the metadata (so we can layout prior to the image being loaded) and schedule the
        /// background task for loading
        imageSizeMetadata = source.sizeFromMetadata
        
        guard let dataManager: ImageDataManagerType = self.dataManager else {
            #if DEBUG
            preconditionFailure("Error! No `ImageDataManager` configured for `SessionImageView")
            #else
            return
            #endif
        }
        
        imageLoadTask = Task { [weak self, dataManager] in
            let processedData: ImageDataManager.ProcessedImageData? = await dataManager.loadImageData(
                identifier: identifier,
                source: source
            )
            
            await MainActor.run { [weak self] in
                guard !Task.isCancelled && self?.currentLoadIdentifier == identifier else { return }
                
                self?.handleLoadedImageData(processedData)
                onComplete?()
            }
        }
    }
    
    @MainActor
    private func resetState(identifier: String?) {
        stopAnimationLoop()
        self.image = nil
        
        currentLoadIdentifier = identifier
        animationFrames = nil
        animationFrameDurations = nil
        currentFrameIndex = 0
        accumulatedTime = 0
        imageSizeMetadata = nil
    }
    
    @MainActor
    private func handleLoadedImageData(_ data: ImageDataManager.ProcessedImageData?) {
        guard let data: ImageDataManager.ProcessedImageData = data else {
            self.image = nil
            stopAnimationLoop()
            return
        }

        switch data.type {
            case .staticImage(let staticImg):
                stopAnimationLoop()
                self.image = staticImg
                self.animationFrames = nil
                self.animationFrameDurations = nil
            
            case .animatedImage(let frames, let durations):
                self.image = frames.first
                self.animationFrames = frames
                self.animationFrameDurations = durations
                self.currentFrameIndex = 0
                self.accumulatedTime = 0
                
                switch frames.count {
                    case 1...: startAnimationLoop()
                    default: stopAnimationLoop()    /// Treat as a static image
                }
        }
    }
    
    @objc private func updateFrame(displayLink: CADisplayLink) {
        /// Stop animating if we don't have a valid animation state
        guard
            let frames: [UIImage] = animationFrames,
            let durations = animationFrameDurations,
            !frames.isEmpty,
            frames.count == durations.count,
            currentFrameIndex < durations.count
        else { return stopAnimationLoop() }
        
        accumulatedTime += displayLink.duration
        
        let currentFrameDuration: TimeInterval = durations[currentFrameIndex]
        
        /// It's possible for a long `CADisplayLink` tick to take longeer than a single frame so try to handle those cases
        while accumulatedTime >= currentFrameDuration {
            accumulatedTime -= currentFrameDuration
            currentFrameIndex = (currentFrameIndex + 1) % frames.count
            
            /// Check if we need to break after advancing to the next frame
            if currentFrameIndex < durations.count, accumulatedTime < durations[currentFrameIndex] {
                break
            }
            
            /// Prevent an infinite loop for all zero durations
            if
                durations[currentFrameIndex] <= 0.001 &&
                currentFrameIndex == (currentFrameIndex + 1) % frames.count
            {
                break
            }
        }
        
        /// Make sure we don't cause an index-out-of-bounds somehow
        guard currentFrameIndex < frames.count else { return stopAnimationLoop() }
        
        /// Set the image using `super.image` as `self.image` is overwritten to stop the animation (in case it gets called
        /// to replace the current image with something else)
        super.image = frames[currentFrameIndex]
    }
}
