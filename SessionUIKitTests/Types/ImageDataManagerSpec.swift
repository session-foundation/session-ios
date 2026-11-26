// Copyright © 2026 Session Technology Foundation. All rights reserved.

import UIKit
import ImageIO
import UniformTypeIdentifiers
import Quick
import Nimble

@testable import SessionUIKit

class ImageDataManagerSpec: AsyncSpec {
    override class func spec() {
        // MARK: Configuration
        
        let frameCount: Int = 20
        let frameSize: Int = 100
        let plentyOfMemory: Int = (1 << 40)
        
        /// A synthetic animated GIF with enough frames for the loader to measure decode time before buffering
        func makeAnimatedSource() -> CGImageSource? {
            let data: NSMutableData = NSMutableData()
            
            guard
                let destination: CGImageDestination = CGImageDestinationCreateWithData(
                    data as CFMutableData,
                    UTType.gif.identifier as CFString,
                    frameCount,
                    nil
                )
            else { return nil }
            
            for index in 0..<frameCount {
                let context: CGContext? = CGContext(
                    data: nil,
                    width: frameSize,
                    height: frameSize,
                    bitsPerComponent: 8,
                    bytesPerRow: (frameSize * 4),
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
                context?.setFillColor(UIColor(white: (CGFloat(index) / CGFloat(frameCount)), alpha: 1).cgColor)
                context?.fill(CGRect(x: 0, y: 0, width: frameSize, height: frameSize))
                
                guard let frame: CGImage = context?.makeImage() else { return nil }
                
                CGImageDestinationAddImage(
                    destination,
                    frame,
                    [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.05]] as CFDictionary
                )
            }
            
            guard CGImageDestinationFinalize(destination) else { return nil }
            
            return CGImageSourceCreateWithData(data as CFData, nil)
        }
        
        /// Reports plenty of memory for the first `count` checks and none after that
        func memoryRunningOut(after count: Int) -> @Sendable () -> Int? {
            let checks: Counter = Counter()
            
            return { (checks.increment() <= count ? plentyOfMemory : 0) }
        }
        
        func loadAllFrames(availableMemory: @escaping @Sendable () -> Int?) async -> ImageDataManager.FrameBuffer? {
            guard let source: CGImageSource = makeAnimatedSource() else { return nil }
            
            let buffer: ImageDataManager.FrameBuffer? = await ImageDataManager.createBuffer(
                source,
                orientation: .up,
                sourceWidth: frameSize,
                sourceHeight: frameSize,
                availableMemory: availableMemory
            )
            _ = await buffer?.stream.first(where: { $0 == .completed })
            
            return buffer
        }
        
        func loadedFrameIndexes(in buffer: ImageDataManager.FrameBuffer?) -> [Int] {
            guard let buffer: ImageDataManager.FrameBuffer = buffer else { return [] }
            
            return (0..<buffer.frameCount).filter { buffer.getFrame(at: $0) != nil }
        }
        
        // MARK: - an ImageDataManager
        describe("an ImageDataManager") {
            // MARK: -- when checking whether there is memory to decode
            context("when checking whether there is memory to decode") {
                // MARK: ---- assumes there is enough when the available memory is unknown
                it("assumes there is enough when the available memory is unknown") {
                    expect(ImageDataManager.hasMemoryToDecode(sourceWidth: 4000, sourceHeight: 4000, availableMemory: nil))
                        .to(beTrue())
                }
                
                // MARK: ---- requires room for three times the canvas
                it("requires room for three times the canvas") {
                    /// 1000x1000 at 4 bytes per pixel is 4MB, so decoding needs 12MB within 80% of what's available
                    expect(ImageDataManager.hasMemoryToDecode(sourceWidth: 1000, sourceHeight: 1000, availableMemory: 16_000_000))
                        .to(beTrue())
                    expect(ImageDataManager.hasMemoryToDecode(sourceWidth: 1000, sourceHeight: 1000, availableMemory: 15_000_000))
                        .to(beFalse())
                }
            }
            
            // MARK: -- when loading an animated image
            context("when loading an animated image") {
                // MARK: ---- decodes every frame when there is enough memory
                it("decodes every frame when there is enough memory") {
                    let buffer: ImageDataManager.FrameBuffer? = await loadAllFrames(availableMemory: { plentyOfMemory })
                    
                    expect(buffer?.frameCount).to(equal(frameCount))
                    expect(buffer?.isComplete).to(beTrue())
                    expect(loadedFrameIndexes(in: buffer)).to(equal(Array(0..<frameCount)))
                }
                
                // MARK: ---- stops decoding and keeps the loaded frames when memory runs low
                it("stops decoding and keeps the loaded frames when memory runs low") {
                    /// One check for the first frame then one before each of the next four
                    let buffer: ImageDataManager.FrameBuffer? = await loadAllFrames(availableMemory: memoryRunningOut(after: 5))
                    
                    expect(buffer?.frameCount).to(equal(frameCount))
                    expect(buffer?.isComplete).to(beTrue())
                    expect(loadedFrameIndexes(in: buffer)).to(equal([0, 1, 2, 3, 4]))
                }
                
                // MARK: ---- decodes no further frames when memory is already low after the first
                it("decodes no further frames when memory is already low after the first") {
                    let buffer: ImageDataManager.FrameBuffer? = await loadAllFrames(availableMemory: memoryRunningOut(after: 1))
                    
                    expect(buffer?.isComplete).to(beTrue())
                    expect(loadedFrameIndexes(in: buffer)).to(equal([0]))
                }
            }
        }
    }
}

// MARK: - Counter

private final class Counter: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var value: Int = 0
    
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        
        value += 1
        return value
    }
}
