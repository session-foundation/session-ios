// Copyright © 2026 Session Technology Foundation. All rights reserved.

import UIKit
import Quick
import Nimble

@testable import Session

class MediaLoaderViewSpec: AsyncSpec {
    override class func spec() {
        @TestState var window: UIWindow!
        
        beforeEach {
            window = await MainActor.run {
                /// A window only counts as on-screen when it belongs to a scene
                let scene: UIWindowScene? = UIApplication.shared.connectedScenes.first as? UIWindowScene
                let window: UIWindow = (scene.map { UIWindow(windowScene: $0) } ?? UIWindow())
                window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
                window.isHidden = false
                
                return window
            }
        }
        
        afterEach {
            await MainActor.run { window.isHidden = true }
        }
        
        // MARK: - a MediaLoaderView
        describe("a MediaLoaderView") {
            // MARK: -- does not wake the main run loop while hidden
            it("does not wake the main run loop while hidden") {
                let baseline: MainThreadActivity = await MainThreadActivity.measure(overSeconds: 2)
                let loaders: [MediaLoaderView] = await MainActor.run {
                    (0..<100).map { _ in
                        let loader: MediaLoaderView = MediaLoaderView(frame: CGRect(x: 0, y: 0, width: 200, height: 8))
                        loader.isHidden = true
                        window.addSubview(loader)
                        
                        return loader
                    }
                }
                let withLoaders: MainThreadActivity = await MainThreadActivity.measure(overSeconds: 2)
                print("[MediaLoaderViewSpec] hidden in a window, over 2s: baseline \(baseline), with 100 loaders \(withLoaders)")
                
                expect(withLoaders.timerWakeUps - baseline.timerWakeUps).to(beLessThan(20))
                expect(loaders.count).to(equal(100))
            }
            
            // MARK: -- does not wake the main run loop while not in a window
            it("does not wake the main run loop while not in a window") {
                let baseline: MainThreadActivity = await MainThreadActivity.measure(overSeconds: 2)
                let loaders: [MediaLoaderView] = await MainActor.run {
                    (0..<100).map { _ in MediaLoaderView(frame: CGRect(x: 0, y: 0, width: 200, height: 8)) }
                }
                let withLoaders: MainThreadActivity = await MainThreadActivity.measure(overSeconds: 2)
                print("[MediaLoaderViewSpec] not in a window, over 2s: baseline \(baseline), with 100 loaders \(withLoaders)")
                
                expect(withLoaders.timerWakeUps - baseline.timerWakeUps).to(beLessThan(20))
                expect(loaders.count).to(equal(100))
            }
            
            // MARK: -- animates while visible in a window
            it("animates while visible in a window") {
                let loader: MediaLoaderView = await MainActor.run {
                    let loader: MediaLoaderView = MediaLoaderView(frame: CGRect(x: 0, y: 0, width: 200, height: 8))
                    window.addSubview(loader)
                    
                    return loader
                }
                
                /// The loop pauses for 0.25s between some steps, so sample across a whole cycle
                var sawAnimation: Bool = false
                
                for _ in 0..<30 where !sawAnimation {
                    try await Task.sleep(nanoseconds: 50_000_000)
                    sawAnimation = await MainActor.run {
                        loader.subviews.contains { $0.layer.animationKeys()?.isEmpty == false }
                    }
                }
                
                expect(sawAnimation).to(beTrue())
            }
        }
    }
}

// MARK: - MainThreadActivity

private struct MainThreadActivity: CustomStringConvertible {
    let timerWakeUps: Int
    let cpuMilliseconds: Double
    
    var description: String { "\(timerWakeUps) timer wake-ups / \(String(format: "%.1f", cpuMilliseconds))ms main-thread CPU" }
    
    static func measure(overSeconds seconds: UInt64) async -> MainThreadActivity {
        let counter: Counter = Counter()
        let observer: CFRunLoopObserver = CFRunLoopObserverCreateWithHandler(
            nil,
            CFRunLoopActivity.beforeTimers.rawValue,
            true,
            0
        ) { _, _ in counter.value += 1 }
        let mainThread: mach_port_t = await MainActor.run { mach_thread_self() }
        let cpuBefore: Double = cpuMilliseconds(of: mainThread)
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        let cpuAfter: Double = cpuMilliseconds(of: mainThread)
        
        return await MainActor.run {
            MainThreadActivity(timerWakeUps: counter.value, cpuMilliseconds: (cpuAfter - cpuBefore))
        }
    }
    
    private static func cpuMilliseconds(of thread: mach_port_t) -> Double {
        var info: thread_basic_info = thread_basic_info()
        var count: mach_msg_type_number_t = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let result: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        
        return (
            Double(info.user_time.seconds + info.system_time.seconds) * 1000 +
            Double(info.user_time.microseconds + info.system_time.microseconds) / 1000
        )
    }
}

/// Only touched from the main run loop's observer callback and then read on the main actor
private final class Counter: @unchecked Sendable {
    var value: Int = 0
}
