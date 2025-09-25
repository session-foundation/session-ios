// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import ImageIO

public class SessionImageView: UIImageView {
    private var dataManager: ImageDataManagerType?
    
    private var currentLoadIdentifier: String?
    private var imageLoadTask: Task<Void, Never>?
    private var streamConsumptionTask: Task<Void, Never>?
    
    private var displayLink: CADisplayLink?
    private var animationFrames: [UIImage?]?
    private var animationFrameDurations: [TimeInterval]?
    public private(set) var currentFrameIndex: Int = 0
    public private(set) var accumulatedTime: TimeInterval = 0
    
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
    
    public var shouldAnimateImage: Bool = true {
        didSet {
            guard oldValue != shouldAnimateImage else { return }
            
            if shouldAnimateImage {
                startAnimationLoop()
            } else {
                stopAnimationLoop()
            }
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
        streamConsumptionTask?.cancel()
        
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
    public func loadImage(_ source: ImageDataManager.DataSource, onComplete: (@MainActor (ImageDataManager.ProcessedImageData?) -> Void)? = nil) {
        /// If we are trying to load the image that is already displayed then no need to do anything
        if currentLoadIdentifier == source.identifier && (self.image == nil || isAnimating()) {
            /// If it was an animation that got paused then resume it
            if let frames: [UIImage?] = animationFrames, !frames.isEmpty, frames[0] != nil, !isAnimating() {
                startAnimationLoop()
            }
            return
        }
        
        imageLoadTask?.cancel()
        resetState(identifier: source.identifier)
        
        /// No need to kick of an async task if we were given an image directly
        switch source {
            case .image(_, .some(let image)):
                let processedData: ImageDataManager.ProcessedImageData = ImageDataManager.ProcessedImageData(
                    type: .staticImage(image)
                )
                imageSizeMetadata = image.size
                handleLoadedImageData(processedData)
                onComplete?(processedData)
                return
            
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
        
        imageLoadTask = Task.detached(priority: .userInitiated) { [weak self, dataManager] in
            let processedData: ImageDataManager.ProcessedImageData? = await dataManager.load(source)
            
            await MainActor.run { [weak self] in
                guard !Task.isCancelled && self?.currentLoadIdentifier == source.identifier else { return }
                
                self?.handleLoadedImageData(processedData)
                onComplete?(processedData)
            }
        }
    }
    
    @MainActor
    public func startAnimationLoop() {
        guard
            shouldAnimateImage,
            let frames: [UIImage?] = animationFrames,
            let durations: [TimeInterval] = animationFrameDurations,
            !frames.isEmpty,
            !durations.isEmpty
        else { return stopAnimationLoop() }
        
        /// If it's already running (or paused) then no need to start the animation loop
        guard displayLink == nil else {
            displayLink?.isPaused = false
            return
        }
        
        /// Just to be safe set the initial frame
        if self.image == nil, !frames.isEmpty, frames[0] != nil {
            self.image = frames[0]
        }
        
        stopAnimationLoop() /// Make sure we don't unintentionally create extra `CADisplayLink` instances
        currentFrameIndex = 0
        accumulatedTime = 0

        displayLink = CADisplayLink(target: self, selector: #selector(updateFrame))
        displayLink?.add(to: .main, forMode: .common)
    }
    
    @MainActor
    public func setAnimationPoint(index: Int, time: TimeInterval) {
        guard index >= 0, index < animationFrames?.count ?? 0 else { return }
        currentFrameIndex = index
        self.image = animationFrames?[index]
        
        /// Stop animating if we don't have a valid animation state
        guard
            let frames: [UIImage?] = animationFrames,
            let durations = animationFrameDurations,
            !frames.isEmpty,
            frames.count == durations.count,
            index >= 0,
            index < durations.count,
            time > 0,
            time < durations.reduce(0, +)
        else { return stopAnimationLoop() }
        
        /// Update the values
        accumulatedTime = time
        currentFrameIndex = index
        
        /// Set the image using `super.image` as `self.image` is overwritten to stop the animation (in case it gets called
        /// to replace the current image with something else)
        super.image = frames[currentFrameIndex]
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
    private func resetState(identifier: String?) {
        stopAnimationLoop()
        streamConsumptionTask?.cancel()
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
                
                guard self.shouldAnimateImage else { return }
                
                switch frames.count {
                    case 1...: startAnimationLoop()
                    default: stopAnimationLoop()    /// Treat as a static image
                }
                
            case .bufferedAnimatedImage(let firstFrame, let durations, let bufferedFrameStream):
                self.image = firstFrame
                self.animationFrameDurations = durations
                self.animationFrames = Array(repeating: nil, count: durations.count)
                self.animationFrames?[0] = firstFrame
                
                guard durations.count > 1 else {
                    stopAnimationLoop()
                    return
                }
                
                streamConsumptionTask = Task { @MainActor in
                    for await event in bufferedFrameStream {
                        guard !Task.isCancelled else { break }
                        
                        switch event {
                            case .frame(let index, let frame): self.animationFrames?[index] = frame
                            case .readyToPlay:
                                guard self.shouldAnimateImage else { continue }
                                
                                startAnimationLoop()
                        }
                    }
                }
        }
    }
    
    @objc private func updateFrame(displayLink: CADisplayLink) {
        /// Stop animating if we don't have a valid animation state
        guard
            let frames: [UIImage?] = animationFrames,
            let durations = animationFrameDurations,
            !frames.isEmpty,
            !durations.isEmpty,
            currentFrameIndex < durations.count
        else { return stopAnimationLoop() }
        
        accumulatedTime += displayLink.duration
        
        var currentFrameDuration: TimeInterval = durations[currentFrameIndex]
        
        /// It's possible for a long `CADisplayLink` tick to take longeer than a single frame so try to handle those cases
        while accumulatedTime >= currentFrameDuration {
            accumulatedTime -= currentFrameDuration

            
            let nextFrameIndex: Int = ((currentFrameIndex + 1) % durations.count)
            
            /// If the next frame hasn't been decoded yet, pause on the current frame, we'll re-evaluate on the next display tick.
            guard nextFrameIndex < frames.count, frames[nextFrameIndex] != nil else { break }
            
            /// Prevent an infinite loop for all zero durations
            guard durations[nextFrameIndex] > 0.001 else { break }
            
            currentFrameIndex = nextFrameIndex
            currentFrameDuration = durations[currentFrameIndex]
        }
        
        /// Make sure we don't cause an index-out-of-bounds somehow
        guard currentFrameIndex < frames.count else { return stopAnimationLoop() }
        
        /// Set the image using `super.image` as `self.image` is overwritten to stop the animation (in case it gets called
        /// to replace the current image with something else)
        super.image = frames[currentFrameIndex]
    }
}
