// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Combine
import NaturalLanguage

public struct SessionAsyncImage<Content: View, Placeholder: View>: View {
    @State private var loadedImage: UIImage? = nil
    @State private var frameBuffer: ImageDataManager.FrameBuffer?
    @State private var isAnimating: Bool = false
    
    @State private var currentFrameIndex: Int = 0
    @State private var accumulatedTime: TimeInterval = 0.0
    @State private var lastFrameDate: Date? = nil
    
    private let source: ImageDataManager.DataSource
    private let dataManager: ImageDataManagerType
    private let shouldAnimateImage: Bool
    
    private let content: (Image) -> Content
    private let placeholder: () -> Placeholder
    
    public init(
        source: ImageDataManager.DataSource,
        dataManager: ImageDataManagerType,
        shouldAnimateImage: Bool = true,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.source = source
        self.dataManager = dataManager
        self.shouldAnimateImage = shouldAnimateImage
        self.content = content
        self.placeholder = placeholder
    }
    
    public var body: some View {
        ZStack {
            if let uiImage = loadedImage {
                let imageView = content(Image(uiImage: uiImage))
                
                if isAnimating {
                    TimelineView(.animation) { context in
                        imageView
                            .onChange(of: context.date) { newDate in
                                updateAnimationFrame(at: newDate)
                            }
                    }
                }
                else {
                    imageView
                }
            } else {
                placeholder()
            }
        }
        .task(id: source.identifier) {
            await loadAndProcessData()
        }
        .onChange(of: shouldAnimateImage) { newValue in
            if let buffer = frameBuffer, !buffer.durations.isEmpty {
                isAnimating = newValue
            }
        }
    }
    
    // MARK: - Internal Functions
    
    private func loadAndProcessData() async {
        /// Reset the state before loading new data
        await MainActor.run { resetAnimationState() }
        
        guard let buffer: ImageDataManager.FrameBuffer = await dataManager.load(source) else {
            return await MainActor.run {
                self.loadedImage = nil
                self.frameBuffer = nil
            }
        }
        
        guard !Task.isCancelled else { return }
        
        /// Set the first frame
        await MainActor.run {
            self.loadedImage = buffer.firstFrame
            self.frameBuffer = buffer
            self.currentFrameIndex = 0
            self.accumulatedTime = 0.0
        }
        
        guard buffer.durations.count > 1 && self.shouldAnimateImage else {
            self.isAnimating = false /// Treat as a static image
            return
        }
        
        for await event in buffer.stream {
            guard !Task.isCancelled else { break }
            
            await MainActor.run {
                switch event {
                    case .frameLoaded, .completed: break
                    case .readyToAnimate:
                        guard self.shouldAnimateImage else { return }
                        
                        self.isAnimating = true
                }
            }
        }
    }
    
    @MainActor
    private func resetAnimationState() {
        self.loadedImage = nil
        self.frameBuffer = nil
        self.isAnimating = false
        self.currentFrameIndex = 0
        self.accumulatedTime = 0.0
        self.lastFrameDate = .now
    }
    
    private func updateAnimationFrame(at date: Date) {
        guard
            isAnimating,
            let buffer: ImageDataManager.FrameBuffer = frameBuffer,
            !buffer.durations.isEmpty,
            currentFrameIndex < buffer.durations.count,
            let lastDate = lastFrameDate
        else {
            isAnimating = false
            return
        }
        
        /// Calculate elapsed time since the last frame
        let elapsed: TimeInterval = date.timeIntervalSince(lastDate)
        self.lastFrameDate = date
        accumulatedTime += elapsed
        
        var currentFrameDuration: TimeInterval = buffer.durations[currentFrameIndex]
        
        // Advance frames if the accumulated time exceeds the current frame's duration
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
        guard currentFrameIndex < buffer.durations.count else {
            isAnimating = false
            return
        }
        
        /// Update the displayed image only if the frame has changed
        if
            let nextFrame: UIImage = buffer.getFrame(at: currentFrameIndex),
            loadedImage !== nextFrame
        {
            loadedImage = nextFrame
        }
    }
}

// MARK: - Convenience

extension SessionAsyncImage where Content == Image, Placeholder == ProgressView<EmptyView, EmptyView> {
    init(
        identifier: String,
        source: ImageDataManager.DataSource,
        dataManager: ImageDataManagerType
    ) {
        self.init(
            source: source,
            dataManager: dataManager,
            content: { $0.resizable() },
            placeholder: { ProgressView() }
        )
    }
}
