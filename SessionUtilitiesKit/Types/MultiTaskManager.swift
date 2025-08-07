// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public actor MultiTaskManager<Element> {
    private var tasks: [Task<Element, Never>] = []
    
    public init() {}

    public func add(_ task: Task<Element, Never>) {
        tasks.append(task)
    }

    public func cancelAll() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
    }
}
