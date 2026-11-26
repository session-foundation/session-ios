// Copyright © 2026 Session Technology Foundation. All rights reserved.

import UIKit
import Quick
import Nimble

@testable import SessionUIKit

class FrameBufferSpec: AsyncSpec {
    override class func spec() {
        // MARK: Configuration
        
        /// An animated buffer whose loader counts how many times it is started and never finishes, so it stays "loading"
        func makeBuffer(loaderStarts: LoaderStartCounter) -> ImageDataManager.FrameBuffer {
            return ImageDataManager.FrameBuffer(
                firstFrame: UIImage(),
                durations: Array(repeating: 0.1, count: 10),
                shouldAutoPurgeIfEstimatedCostExceedsLimit: Int.max,
                generateLoadClosure: {
                    loaderStarts.increment()
                    
                    return { _, _ in try? await Task.sleep(for: .seconds(10)) }
                }
            )
        }
        
        // MARK: - a FrameBuffer
        describe("a FrameBuffer") {
            // MARK: -- starts a single loader when frames are requested concurrently
            it("starts a single loader when frames are requested concurrently") {
                let loaderStarts: LoaderStartCounter = LoaderStartCounter()
                let buffer: ImageDataManager.FrameBuffer = makeBuffer(loaderStarts: loaderStarts)
                
                DispatchQueue.concurrentPerform(iterations: 1000) { index in
                    _ = buffer.getFrame(at: (index % buffer.frameCount))
                }
                try? await Task.sleep(for: .milliseconds(500))
                
                expect(loaderStarts.value).to(equal(1))
            }
        }
    }
}

// MARK: - LoaderStartCounter

private final class LoaderStartCounter: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var _value: Int = 0
    
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        
        return _value
    }
    
    func increment() {
        lock.lock()
        _value += 1
        lock.unlock()
    }
}
