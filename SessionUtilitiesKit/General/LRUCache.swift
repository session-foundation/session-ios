// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit

public class LRUCache<KeyType: Hashable & Equatable, ValueType> {
    private var cacheMap: [KeyType: ValueType] = [:]
    private var cacheOrder: [KeyType] = []
    private let maxCacheSize: Int
    private lazy var observer: NotificationObserver = NotificationObserver { [weak self] in
        Task { self?.clear() }
    }
    
    // MARK: - Initialization

    public init(maxCacheSize: Int = 0) {
        self.maxCacheSize = maxCacheSize
    }
    
    // MARK: - Functions

    private func updateCacheOrder(key: KeyType) {
        cacheOrder = cacheOrder.filter { $0 != key }
        cacheOrder.append(key)
    }

    public func get(key: KeyType) -> ValueType? {
        guard let value = cacheMap[key] else { return nil }

        updateCacheOrder(key: key)
        return value
    }

    public func set(key: KeyType, value: ValueType) {
        cacheMap[key] = value
        updateCacheOrder(key: key)
        
        /// If we don't have a `maxCacheSize` then don't bother evicting elements
        guard maxCacheSize > 0 else { return }

        while cacheOrder.count > maxCacheSize {
            guard let staleKey = cacheOrder.first else { return }
            
            cacheOrder.removeFirst()
            cacheMap.removeValue(forKey: staleKey)
        }
    }

    public func clear() {
        cacheMap.removeAll()
        cacheOrder.removeAll()
    }
}

public extension LRUCache {
    func settingObject(_ value: ValueType, forKey key: KeyType) -> LRUCache<KeyType, ValueType> {
        set(key: key, value: value)
        return self
    }
}

// MARK: - LRUCache.NotificationObserver

private extension LRUCache {
    class NotificationObserver {
        private let observers: [NSObjectProtocol]
        
        init(handler: @escaping () -> Void) {
            observers = [
                NotificationCenter.default.addObserver(
                    forName: UIApplication.didReceiveMemoryWarningNotification,
                    object: nil,
                    queue: nil
                ) { _ in handler() },
                NotificationCenter.default.addObserver(
                    forName: .sessionDidEnterBackground,
                    object: nil,
                    queue: nil
                ) { _ in handler() }
            ]
        }
        
        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }
    }
}
