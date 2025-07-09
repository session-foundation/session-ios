// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

/// This is a convenience method to force an async process to run indefinitely until it's parent task gets cancelled
public enum TaskCancellation {
    public static func wait() async {
        let (stream, _) = AsyncStream.makeStream(of: Void.self)
        for await _ in stream {}
    }
}
