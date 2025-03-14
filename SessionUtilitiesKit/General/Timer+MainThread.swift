// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

extension Timer {
    @discardableResult public static func scheduledTimerOnMainThread(
        withTimeInterval timeInterval: TimeInterval,
        repeats: Bool = false,
        using dependencies: Dependencies,
        block: @escaping (Timer) -> Void
    ) -> Timer {
        let timer = Timer(timeInterval: timeInterval, repeats: repeats, block: block)
        
        // If we are forcing synchrnonous execution (ie. running unit tests) then ceil the
        // timeInterval for execution and append it to the execution set so the test can
        // trigger the logic in a synchronous way - the `dependencies.async` function stores
        // the closure and executes it when the `dependencies.stepForwardInTime` is triggered)
        guard !dependencies.forceSynchronous else {
            dependencies.async(at: dependencies.dateNow.timeIntervalSince1970 + timeInterval) {
                block(timer)
            }
            return timer
        }
        
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}

// MARK: - Objective-C Extensions

public extension Timer {
    /// **Note:** We should look to remove the use of this when we can (`OWSAudioPlayer`) as there is no good way to provide the
    /// proper instance of `Dependencies` so it can't be tested well - luckily the usage isn't going to break anything outside of tests
    @objc static func weakScheduledTimer(timeInterval: TimeInterval, repeats: Bool, onFire: @escaping (Timer) -> ()) -> Timer {
        return Timer.scheduledTimerOnMainThread(
            withTimeInterval: timeInterval,
            repeats: repeats,
            using: Dependencies.createEmpty(),
            block: onFire
        )
    }
}
