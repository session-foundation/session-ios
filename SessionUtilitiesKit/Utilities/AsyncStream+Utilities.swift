// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension AsyncStream {
    func first() async -> Element? {
        return await first(where: { _ in true })
    }
    
    func first(defaultValue: Element) async -> Element {
        return (await first(where: { _ in true }) ?? defaultValue)
    }
}
