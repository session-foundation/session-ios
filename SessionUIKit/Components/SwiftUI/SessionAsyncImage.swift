// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Combine
import NaturalLanguage

public struct SessionAsyncImage<Content: View, Placeholder: View>: View {
    @State private var loadedImage: UIImage? = nil
    @State private var animationFrames: [UIImage]?
    @State private var animationFrameDurations: [TimeInterval]?
    @State private var isAnimating: Bool = false
    
    @State private var currentFrameIndex: Int = 0
    @State private var accumulatedTime: TimeInterval = 0.0
    @State private var lastFrameDate: Date? = nil
    
    private let source: ImageDataManager.DataSource
    private let dataManager: ImageDataManagerType
    
    private let content: (Image) -> Content
    private let placeholder: () -> Placeholder
    
    public init(
        source: ImageDataManager.DataSource,
        dataManager: ImageDataManagerType,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.source = source
        self.dataManager = dataManager
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
    }
    
    // MARK: - Internal Functions
    
    private func loadAndProcessData() async {
        let processedData = await dataManager.load(source)
        
        /// Reset the state before loading new data
        await MainActor.run {
            self.loadedImage = nil
            self.animationFrames = nil
            self.animationFrameDurations = nil
            self.isAnimating = false
            self.currentFrameIndex = 0
            self.accumulatedTime = 0.0
            self.lastFrameDate = .now
        }
        
        switch processedData?.type {
            case .staticImage(let image):
                await MainActor.run {
                    self.loadedImage = image
                }
            
            case .animatedImage(let frames, let durations) where frames.count > 1:
                await MainActor.run {
                    self.animationFrames = frames
                    self.animationFrameDurations = durations
                    self.loadedImage = frames.first
                    self.isAnimating = true /// Activate the `TimelineView`
                }
                
            case .animatedImage(let frames, _):
                await MainActor.run {
                    self.loadedImage = frames.first
                }

            default:
                await MainActor.run {
                    self.loadedImage = nil
                }
        }
    }
    
    private func updateAnimationFrame(at date: Date) {
        guard
            isAnimating,
            let frames: [UIImage] = animationFrames,
            let durations = animationFrameDurations,
            !frames.isEmpty,
            frames.count == durations.count,
            currentFrameIndex < durations.count,
            let lastDate = lastFrameDate
        else { return }
        
        /// Calculate elapsed time since the last frame
        let elapsed: TimeInterval = date.timeIntervalSince(lastDate)
        self.lastFrameDate = date
        accumulatedTime += elapsed
        
        let currentFrameDuration: TimeInterval = durations[currentFrameIndex]
        
        // Advance frames if the accumulated time exceeds the current frame's duration
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
        guard currentFrameIndex < frames.count else {
            isAnimating = false
            return
        }
        
        /// Update the displayed image only if the frame has changed
        if loadedImage !== frames[currentFrameIndex] {
            loadedImage = frames[currentFrameIndex]
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
