// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

@testable import SessionUtilitiesKit

public class TestDependencies: Dependencies {
    private var singletonInstances: [Int: Any] = [:]
    private var cacheInstances: [Int: MutableCacheType] = [:]
    
    // MARK: - Subscript Access
    
    override public subscript<S>(singleton singleton: SingletonInfo.Config<S>) -> S {
        return getValueSettingIfNull(singleton: singleton, &singletonInstances)
    }
    
    public subscript<S>(singleton singleton: SingletonInfo.Config<S>) -> S? {
        get { return (singletonInstances[singleton.key] as? S) }
        set { singletonInstances[singleton.key] = newValue }
    }
    
    override public subscript<M, I>(cache cache: CacheInfo.Config<M, I>) -> I {
        return getValueSettingIfNull(cache: cache, &cacheInstances)
    }
    
    public subscript<M, I>(cache cache: CacheInfo.Config<M, I>) -> M? {
        get { return (cacheInstances[cache.key] as? M) }
        set { cacheInstances[cache.key] = newValue.map { cache.mutableInstance($0) } }
    }
    
    // MARK: - Timing and Async Handling

    private var _dateNow: Atomic<Date?>
    override public var dateNow: Date {
        get { (_dateNow.wrappedValue ?? Date()) }
        set { _dateNow.mutate { $0 = newValue } }
    }

    private var _fixedTime: Atomic<Int?>
    override public var fixedTime: Int {
        get { (_fixedTime.wrappedValue ?? 0) }
        set { _fixedTime.mutate { $0 = newValue } }
    }

    // MARK: - Initialization
    
    public init(
        dateNow: Date? = nil,
        fixedTime: Int? = nil,
        forceSynchronous: Bool = false
    ) {
        _dateNow = Atomic(dateNow)
        _fixedTime = Atomic(fixedTime)
        
        super.init()
        
        self.forceSynchronous = forceSynchronous
    }
    
    // MARK: - Functions
    
    @discardableResult override public func mutate<M, I, R>(
        cache: CacheInfo.Config<M, I>,
        _ mutation: (inout M) -> R
    ) -> R {
        var value: M = ((cacheInstances[cache.key] as? M) ?? cache.createInstance(self))
        return mutation(&value)
    }
    
    @discardableResult override public func mutate<M, I, R>(
        cache: CacheInfo.Config<M, I>,
        _ mutation: (inout M) throws -> R
    ) throws -> R {
        var value: M = ((cacheInstances[cache.key] as? M) ?? cache.createInstance(self))
        return try mutation(&value)
    }
    
    public func stepForwardInTime() {
        let targetTime: Int = ((_fixedTime.wrappedValue ?? 0) + 1)
        _fixedTime.mutate { $0 = targetTime }
        
        if let currentDate: Date = _dateNow.wrappedValue {
            _dateNow.mutate { $0 = Date(timeIntervalSince1970: currentDate.timeIntervalSince1970 + 1) }
        }
        
        // Run and clear any executions which should run at the target time
        let targetKeys: [Int] = asyncExecutions.keys
            .filter { $0 <= targetTime }
        targetKeys.forEach { key in
            asyncExecutions[key]?.forEach { $0() }
            asyncExecutions[key] = nil
        }
    }
    
    // MARK: - Instance upserting
    
    @discardableResult private func getValueSettingIfNull<S>(
        singleton: SingletonInfo.Config<S>,
        _ store: inout [Int: Any]
    ) -> S {
        guard let value: S = (store[singleton.key] as? S) else {
            let value: S = singleton.createInstance(self)
            store[singleton.key] = value
            return value
        }

        return value
    }
    
    @discardableResult private func getValueSettingIfNull<M, I>(
        cache: CacheInfo.Config<M, I>,
        _ store: inout [Int: MutableCacheType]
    ) -> I {
        guard let value: M = (store[cache.key] as? M) else {
            let value: M = cache.createInstance(self)
            let mutableInstance: MutableCacheType = cache.mutableInstance(value)
            store[cache.key] = mutableInstance
            return cache.immutableInstance(value)
        }
        
        return cache.immutableInstance(value)
    }
}
