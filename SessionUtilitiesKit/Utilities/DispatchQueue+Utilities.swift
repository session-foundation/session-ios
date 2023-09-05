// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension DispatchQueue {
    func async(
        group: DispatchGroup? = nil,
        qos: DispatchQoS = .unspecified,
        flags: DispatchWorkItemFlags = [],
        using dependencies: Dependencies,
        execute work: @escaping () -> Void
    ) {
        guard !dependencies.forceSynchronous else { return work() }
        
        return self.async(group: group, qos: qos, flags: flags, execute: work)
    }
    
    func asyncAfter(
        deadline: DispatchTime,
        qos: DispatchQoS = .unspecified,
        flags: DispatchWorkItemFlags = [],
        using dependencies: Dependencies,
        execute work: @escaping  () -> Void
    ) {
        guard !dependencies.forceSynchronous else { return work() }
        
        self.asyncAfter(deadline: deadline, qos: qos, flags: flags, execute: work)
    }
    
    static func with(key: DispatchSpecificKey<String>, matches context: String, using dependencies: Dependencies) -> Bool {
        guard !dependencies.forceSynchronous else { return true }
        
        return (DispatchQueue.getSpecific(key: key) == context)
    }
}
