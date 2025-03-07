// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine

public extension Scheduler {
    func schedule(
        using dependencies: Dependencies,
        _ action: @escaping () -> Void
    ) {
        guard !dependencies.forceSynchronous else { return action() }
        
        return self.schedule(action)
    }
    
    func schedule(
        after date: Self.SchedulerTimeType,
        using dependencies: Dependencies,
        _ action: @escaping () -> Void
    ) {
        guard !dependencies.forceSynchronous else { return action() }
        
        self.schedule(after: date, action)
    }
    
    func schedule(
        after date: Self.SchedulerTimeType,
        tolerance: Self.SchedulerTimeType.Stride,
        using dependencies: Dependencies,
        _ action: @escaping () -> Void
    ) {
        guard !dependencies.forceSynchronous else { return action() }
        
        self.schedule(after: date, tolerance: tolerance, action)
    }
}
