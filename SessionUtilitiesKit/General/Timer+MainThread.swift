// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

extension Timer {
    @discardableResult public static func scheduledTimerOnMainThread(
        withTimeInterval timeInterval: TimeInterval,
        repeats: Bool = false,
        block: @escaping (Timer) -> Void
    ) -> Timer {
        let timer = Timer(timeInterval: timeInterval, repeats: repeats, block: block)
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
            block: onFire
        )
    }
}
