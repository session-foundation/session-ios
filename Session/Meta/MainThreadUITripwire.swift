// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.
// stringlint:disable

#if DEBUG

import UIKit
import QuartzCore
import SessionUtilitiesKit

public extension Log.Category {
    static let mainThreadUITripwire: Log.Category = .create("MainThreadUITripwire", defaultLevel: .error)
}

/// DEBUG-only diagnostic for the `CoreAutoLayout: _AssertAutoLayoutOnAllowedThreadsOnly` crash (the #1 iOS crash).
///
/// **The problem being hunted**
/// That crash never shows any app frames because it is *deferred*: some code touches a `CALayer`/`UIView` on a
/// background (workqueue) thread, Core Animation lazily opens an *implicit* `CATransaction` in that thread's local
/// storage, and the transaction is only committed later when the thread is torn down (`CA::Transaction::release_thread`
/// via `_pthread_tsd_cleanup`). That deferred commit runs Auto Layout off the main thread and aborts. Because the abort
/// is decoupled from the original off-main touch, the production stack is useless and `@MainActor` annotations (which
/// aren't runtime-enforced in this Swift 5 / minimal-concurrency build) don't help.
///
/// **What this catches**
/// This installs method swizzles on `CALayer` layout/display/hierarchy entry points and logs a full call stack the moment
/// any of them is invoked off the main thread — i.e. it reports the *cause* (the off-main touch) rather than the *symptom*
/// (the eventual abort). Crucially you do **not** need to reproduce the crash: the off-main touch happens every time the
/// offending path runs, which for the #1 crash is frequent, so ordinary use (or an Appium pass) should surface it.
///
/// **How to use**
/// 1. Run a DEBUG build and exercise the app (conversation list, opening conversations with media/GIFs, profile pictures,
///    calls, media viewer, share extension flows, etc.).
/// 2. Watch the logs for `[MainThreadUITripwire]` entries, or set a symbolic breakpoint on
///    `SNOffMainThreadUIMutationDetected` to break live in Xcode with the real thread + stack.
/// 3. The `owner` class in the report (the `CALayer.delegate`, usually the owning `UIView` subclass) plus the stack point
///    straight at the site to fix. Fix by guaranteeing the touch/release happens on the main thread.
///
/// This whole file is compiled out of release builds.
public enum MainThreadUITripwire {
    /// Set this to `false` before `install()` if you only want the log line without pausing the debugger.
    public static var breakOnDetection: Bool = true

    private static var isInstalled: Bool = false

    /// Limits log spam: we only report each distinct `operation|owner` pairing once. Guarded by `reportLock` since it is
    /// (by definition) touched from arbitrary background threads.
    private static let reportLock: NSLock = NSLock()
    private static var reportedSignatures: Set<String> = []

    /// Install the swizzles. Safe to call once, early in app launch. No-op if already installed.
    public static func install() {
        guard !isInstalled else { return }
        isInstalled = true

        // Swizzle the low-level `CALayer` choke points. Working at the layer level (rather than `UIView`) also catches
        // raw `layer.*` mutations and teardown (`removeFromSuperlayer`) that bypass the `UIView` API entirely.
        swizzle(original: "setNeedsLayout", replacement: #selector(CALayer.snui_setNeedsLayout))
        swizzle(original: "setNeedsDisplay", replacement: #selector(CALayer.snui_setNeedsDisplay))
        swizzle(original: "layoutIfNeeded", replacement: #selector(CALayer.snui_layoutIfNeeded))
        swizzle(original: "removeFromSuperlayer", replacement: #selector(CALayer.snui_removeFromSuperlayer))
        swizzle(original: "addSublayer:", replacement: #selector(CALayer.snui_addSublayer(_:)))

        Log.info(.mainThreadUITripwire, "Installed off-main CALayer detection (DEBUG only).")
    }

    private static func swizzle(original originalName: String, replacement: Selector) {
        let originalSelector: Selector = NSSelectorFromString(originalName)

        guard
            let originalMethod: Method = class_getInstanceMethod(CALayer.self, originalSelector),
            let replacementMethod: Method = class_getInstanceMethod(CALayer.self, replacement)
        else {
            Log.error(.mainThreadUITripwire, "Failed to swizzle '\(originalName)' - method not found.")
            return
        }

        method_exchangeImplementations(originalMethod, replacementMethod)
    }

    /// Called by the swizzled methods when they run off the main thread.
    fileprivate static func report(operation: String, layer: CALayer) {
        let owner: String = {
            guard let delegate = layer.delegate else { return String(describing: type(of: layer)) }

            return String(describing: type(of: delegate))
        }()
        let signature: String = "\(operation)|\(owner)"

        reportLock.lock()
        let isNew: Bool = reportedSignatures.insert(signature).inserted
        reportLock.unlock()

        /// Only log/break the first time we see a given `operation|owner` pairing to avoid flooding the log with the same
        /// site over and over (the goal is to enumerate the distinct offending sites, not count occurrences).
        guard isNew else { return }

        let stack: String = Thread.callStackSymbols.joined(separator: "\n")
        Log.error(
            .mainThreadUITripwire,
            "OFF-MAIN CALayer.\(operation) on '\(owner)' (thread: \(Thread.current)).\nCall stack:\n\(stack)"
        )

        SNOffMainThreadUIMutationDetected()
    }
}

/// Symbolic-breakpoint anchor. Set a breakpoint on `SNOffMainThreadUIMutationDetected` in Xcode to pause on the live
/// off-main call with the real backtrace. Kept `@inline(never)` so the symbol always exists.
@inline(never)
public func SNOffMainThreadUIMutationDetected() {
    guard MainThreadUITripwire.breakOnDetection else { return }

    /// `SIGSTOP`-style pause via the debugger only fires meaningfully when a debugger is attached; otherwise this is a
    /// no-op beyond the log line already emitted.
    #if targetEnvironment(simulator) || DEBUG
    // Intentionally empty - exists purely as a stable symbol for a symbolic breakpoint.
    #endif
}

// MARK: - Swizzled implementations

private extension CALayer {
    /// **Note:** After `method_exchangeImplementations` each `snui_*` name points at the *original* implementation, so the
    /// trailing self-call below invokes the real method (this is the standard swizzle idiom, not infinite recursion).

    @objc dynamic func snui_setNeedsLayout() {
        if !Thread.isMainThread { MainThreadUITripwire.report(operation: "setNeedsLayout", layer: self) }
        snui_setNeedsLayout()
    }

    @objc dynamic func snui_setNeedsDisplay() {
        if !Thread.isMainThread { MainThreadUITripwire.report(operation: "setNeedsDisplay", layer: self) }
        snui_setNeedsDisplay()
    }

    @objc dynamic func snui_layoutIfNeeded() {
        if !Thread.isMainThread { MainThreadUITripwire.report(operation: "layoutIfNeeded", layer: self) }
        snui_layoutIfNeeded()
    }

    @objc dynamic func snui_removeFromSuperlayer() {
        if !Thread.isMainThread { MainThreadUITripwire.report(operation: "removeFromSuperlayer", layer: self) }
        snui_removeFromSuperlayer()
    }

    @objc dynamic func snui_addSublayer(_ layer: CALayer) {
        if !Thread.isMainThread { MainThreadUITripwire.report(operation: "addSublayer:", layer: self) }
        snui_addSublayer(layer)
    }
}

#endif
