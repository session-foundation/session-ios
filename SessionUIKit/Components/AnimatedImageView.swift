// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import ImageIO

public class AnimatedImageView: UIImageView {
    private var imageSource: CGImageSource?
    private var frameCount: Int = 0
    private var frameDurations: [TimeInterval] = []
    private var totalDuration: TimeInterval = 0
    private var displayLink: CADisplayLink?
    private var currentFrame: Int = 0
    private var currentTime: TimeInterval = 0
    
    // MARK: - Functions
    
    public func loadAnimatedImage(from path: String) {
        loadAnimatedImage(from: URL(fileURLWithPath: path))
    }
    
    public func loadAnimatedImage(from url: URL) {
        guard let imageSource: CGImageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
        
        loadAnimatedImage(from: imageSource)
    }
    
    public func loadAnimatedImage(from data: Data?) {
        guard
            let data: Data = data,
            let imageSource: CGImageSource = CGImageSourceCreateWithData(data as CFData, nil)
        else { return }
        
        loadAnimatedImage(from: imageSource)
    }
    
    // MARK: - Internal Functions
    
    private func loadAnimatedImage(from source: CGImageSource) {
        self.imageSource = source
        self.frameCount = CGImageSourceGetCount(source)
        
        guard frameCount > 1 else {
            self.image = createImage(at: 0)
            return
        }
        
        calculateFrameDurations()
        startAnimation()
    }
    
    private func calculateFrameDurations() {
        frameDurations = []
        totalDuration = 0
        
        for i in 0..<frameCount {
            let duration = frameDuration(at: i)
            frameDurations.append(duration)
            totalDuration += duration
        }
    }
    
    private func frameDuration(at index: Int) -> TimeInterval {
        guard let imageSource: CGImageSource = imageSource, index < frameCount else { return 0.1 }
        
        guard let frameProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, index, nil) as? [String: Any] else {
            return 0.1
        }
        
        if let gifProps = frameProperties[kCGImagePropertyGIFDictionary as String] as? [String: Any],
           let delayTime = gifProps[kCGImagePropertyGIFDelayTime as String] as? Double {
            return delayTime > 0 ? delayTime : 0.1
        }
        
        if let webpProps = frameProperties[kCGImagePropertyWebPDictionary as String] as? [String: Any],
           let delayTime = webpProps[kCGImagePropertyWebPDelayTime as String] as? Double {
            return delayTime > 0 ? delayTime : 0.1
        }
        
        return 0.1
    }
    
    private func createImage(at index: Int) -> UIImage? {
        guard
            let imageSource: CGImageSource = imageSource,
            index < frameCount,
            let cgImage: CGImage = CGImageSourceCreateImageAtIndex(imageSource, index, nil)
        else { return nil }
        
        return UIImage(cgImage: cgImage)
    }
    
    private func startAnimation() {
        stopAnimation()
        currentFrame = 0
        currentTime = 0
        
        // Set the initial frame
        if let image: UIImage = createImage(at: 0) {
            self.image = image
        }
        
        // Add a display link callback to trigger the frame changes
        displayLink = CADisplayLink(target: self, selector: #selector(updateFrame))
        displayLink?.add(to: .main, forMode: .common)
    }
    
    private func stopAnimation() {
        displayLink?.invalidate()
        displayLink = nil
    }
    
    @objc private func updateFrame(displayLink: CADisplayLink) {
        currentTime += displayLink.duration
        
        if currentTime >= frameDurations[currentFrame] {
            currentTime = 0
            currentFrame = (currentFrame + 1) % frameCount
            
            if let image: UIImage = createImage(at: currentFrame) {
                self.image = image
            }
        }
    }
    
    public override func removeFromSuperview() {
        stopAnimation()
        super.removeFromSuperview()
    }
}
