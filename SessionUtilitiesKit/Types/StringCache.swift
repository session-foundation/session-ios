// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public final class StringCache: @unchecked Sendable {
    /// `NSCache` has more nuanced memory management systems than just listening for `didReceiveMemoryWarningNotification`
    /// and can clear out values gradually, it can also remove items based on their "cost" so is better suited than our custom `LRUCache`
    ///
    /// Additionally `NSCache` is thread safe so we don't need to do any custom `ThreadSafeObject` work to interact with it
    private let cache: NSCache<NSString, NSString> = NSCache()
    
    public init(
        name: String? = nil,
        countLimit: Int? = nil,
        totalCostLimit: Int? = nil
    ) {
        if let name: String = name {
            cache.name = name
        }
        
        if let countLimit: Int = countLimit {
            cache.countLimit = countLimit
        }
        
        if let totalCostLimit: Int = totalCostLimit {
            cache.totalCostLimit = totalCostLimit
        }
    }
    
    // MARK: - Functions
    
    public func object(forKey key: String) -> String? {
        return cache.object(forKey: key as NSString) as? String
    }
    
    public func setObject(_ value: String, forKey key: String, cost: Int = 0) {
        cache.setObject(value as NSString, forKey: key as NSString, cost: cost)
    }
    
    public func removeObject(forKey key: String) {
        cache.removeObject(forKey: key as NSString)
    }
    
    public func removeAllObjects() {
        cache.removeAllObjects()
    }
}
