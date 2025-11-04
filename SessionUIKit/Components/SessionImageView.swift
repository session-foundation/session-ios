// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import ImageIO

public class SessionImageView: UIImageView {
    private var dataManager: ImageDataManagerType?
    
    private var currentLoadIdentifier: String?
    private var imageLoadTask: Task<Void, Never>?
    private var streamConsumptionTask: Task<Void, Never>?
    
    private var displayLink: CADisplayLink?
    private var frameBuffer: ImageDataManager.FrameBuffer?
    public private(set) var currentFrameIndex: Int = 0
    public private(set) var accumulatedTime: TimeInterval = 0
    
    public var imageDisplaySizeMetadata: CGSize?
    
    public override var image: UIImage? {
        didSet {
            /// If we set an image directly then it'll be a static image so we should stop the animation loop and remove
            /// any animation data
            imageLoadTask?.cancel()
            stopAnimationLoop()
            currentLoadIdentifier = nil
            frameBuffer = nil
            currentFrameIndex = 0
            accumulatedTime = 0
            imageDisplaySizeMetadata = nil
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
                if let frameBuffer: ImageDataManager.FrameBuffer = frameBuffer, frameBuffer.frameCount > 1 {
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
    public func loadImage(_ source: ImageDataManager.DataSource, onComplete: (@MainActor (ImageDataManager.FrameBuffer?) -> Void)? = nil) {
        /// If we are trying to load the image that is already displayed then no need to do anything
        if currentLoadIdentifier == source.identifier && (self.image == nil || isAnimating()) {
            /// If it was an animation that got paused then resume it
            if let buffer: ImageDataManager.FrameBuffer = frameBuffer, !buffer.durations.isEmpty, !isAnimating() {
                startAnimationLoop()
            }
            return
        }
        
        imageLoadTask?.cancel()
        resetState(identifier: source.identifier)
        
        /// No need to kick of an async task if we were given an image directly
        switch source {
            case .image(_, .some(let image)):
                let buffer: ImageDataManager.FrameBuffer = ImageDataManager.FrameBuffer(image: image)
                handleLoadedImageData(buffer)
                onComplete?(buffer)
                return
            
            default: break
        }
        
        /// Otherwise read the size of the image from the metadata (so we can layout prior to the image being loaded) and schedule the
        /// background task for loading
        imageDisplaySizeMetadata = source.displaySizeFromMetadata
        
        guard let dataManager: ImageDataManagerType = self.dataManager else {
            #if DEBUG
            preconditionFailure("Error! No `ImageDataManager` configured for `SessionImageView")
            #else
            return
            #endif
        }
        
        imageLoadTask = Task.detached(priority: .userInitiated) { [weak self, dataManager] in
            let buffer: ImageDataManager.FrameBuffer? = await dataManager.load(source)
            
            await MainActor.run { [weak self] in
                guard !Task.isCancelled && self?.currentLoadIdentifier == source.identifier else { return }
                
                self?.handleLoadedImageData(buffer)
                onComplete?(buffer)
            }
        }
    }
    
    @MainActor
    public func startAnimationLoop() {
        guard
            shouldAnimateImage,
            let buffer: ImageDataManager.FrameBuffer = frameBuffer,
            !buffer.durations.isEmpty
        else { return stopAnimationLoop() }
        
        /// If it's already running (or paused) then no need to start the animation loop
        guard displayLink == nil else {
            displayLink?.isPaused = false
            return
        }
        
        /// Just to be safe set the initial frame
        if self.image == nil {
            self.image = buffer.firstFrame
        }
        
        stopAnimationLoop() /// Make sure we don't unintentionally create extra `CADisplayLink` instances
        currentFrameIndex = 0
        accumulatedTime = 0

        displayLink = CADisplayLink(target: self, selector: #selector(updateFrame))
        displayLink?.add(to: .main, forMode: .common)
    }
    
    @MainActor
    public func setAnimationPoint(index: Int, time: TimeInterval) {
        guard index >= 0, index < frameBuffer?.frameCount ?? 0 else { return }
        // TODO: Won't this break the animation????
        Task {
//            currentFrameIndex = index
//            self.image = await frameBuffer?.getFrame(at: index)
//            frameBuffer?.
            /// Stop animating if we don't have a valid animation state
            guard
                let durations = frameBuffer?.durations,
                index >= 0,
                index < durations.count,
                time > 0,
                time < durations.reduce(0, +)
            else {
                image = frameBuffer?.getFrame(at: index)
                currentFrameIndex = 0
                accumulatedTime = 0
                return stopAnimationLoop()
            }
            
            /// Update the values
            accumulatedTime = time
            currentFrameIndex = index
            
            /// Set the image using `super.image` as `self.image` is overwritten to stop the animation (in case it gets called
            /// to replace the current image with something else)
            super.image = frameBuffer?.getFrame(at: index)
        }
    }
    
    @MainActor
    public func copyAnimationPoint(from other: SessionImageView) {
        self.handleLoadedImageData(other.frameBuffer)
        self.image = other.image
        self.currentFrameIndex = other.currentFrameIndex
        self.accumulatedTime = other.accumulatedTime
        self.imageDisplaySizeMetadata = other.imageDisplaySizeMetadata
        self.shouldAnimateImage = other.shouldAnimateImage
        
        if other.isAnimating {
            self.startAnimationLoop()
        }
        
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
        frameBuffer = nil
        currentFrameIndex = 0
        accumulatedTime = 0
        imageDisplaySizeMetadata = nil
    }
    
    @MainActor
    private func handleLoadedImageData(_ buffer: ImageDataManager.FrameBuffer?) {
        guard let buffer: ImageDataManager.FrameBuffer = buffer else {
            self.image = nil
            stopAnimationLoop()
            return
        }
        
        /// **Note:** Setting `self.image` will reset the current state and clear any existing animation data so we need to call
        /// it first and then store data afterwards (otherwise it'd just be cleared)
        self.image = buffer.firstFrame
        self.frameBuffer = buffer
        self.imageDisplaySizeMetadata = buffer.firstFrame.size
        
        guard buffer.durations.count > 1 && self.shouldAnimateImage else { return }
        
        Task {
            if buffer.isComplete {
                return await MainActor.run {
                    if self.shouldAnimateImage {
                        self.startAnimationLoop()
                    }
                }
            }
            
            streamConsumptionTask = Task { @MainActor in
                for await event in buffer.stream {
                    guard !Task.isCancelled else { break }
                    
                    switch event {
                        case .frameLoaded, .completed: break
                        case .readyToAnimate:
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
            let buffer: ImageDataManager.FrameBuffer = frameBuffer,
            !buffer.durations.isEmpty,
            currentFrameIndex < buffer.durations.count
        else { return stopAnimationLoop() }
        
        accumulatedTime += displayLink.duration
        
        var currentFrameDuration: TimeInterval = buffer.durations[currentFrameIndex]
        
        /// It's possible for a long `CADisplayLink` tick to take longeer than a single frame so try to handle those cases
        while accumulatedTime >= currentFrameDuration {
            accumulatedTime -= currentFrameDuration
            
            let nextFrameIndex: Int = ((currentFrameIndex + 1) % buffer.durations.count)
            
            /// If the next frame hasn't been decoded yet, pause on the current frame, we'll re-evaluate on the next display tick.
            guard
                nextFrameIndex < buffer.frameCount,
                buffer.getFrame(at: nextFrameIndex) != nil
            else { break }
            
            /// Prevent an infinite loop for all zero durations
            guard buffer.durations[nextFrameIndex] > 0.001 else { break }
            
            currentFrameIndex = nextFrameIndex
            currentFrameDuration = buffer.durations[currentFrameIndex]
        }
        
        /// Make sure we don't cause an index-out-of-bounds somehow
        guard currentFrameIndex < buffer.frameCount else { return stopAnimationLoop() }
        
        /// Set the image using `super.image` as `self.image` is overwritten to stop the animation (in case it gets called
        /// to replace the current image with something else)
        super.image = buffer.getFrame(at: currentFrameIndex)
    }
}
