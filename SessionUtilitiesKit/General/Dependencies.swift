// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

open class Dependencies {
    /// These should not be accessed directly but rather via an instance of this type
    private static let _generalCacheInstance: MutableGeneralCacheType = General.Cache()
    private static let _generalCacheInstanceAccessQueue = DispatchQueue(label: "GeneralCacheInstanceAccess")
    
    public var _subscribeQueue: Atomic<DispatchQueue?>
    public var subscribeQueue: DispatchQueue {
        get { Dependencies.getValueSettingIfNull(&_subscribeQueue) { DispatchQueue.global(qos: .default) } }
        set { _subscribeQueue.mutate { $0 = newValue } }
    }
    
    public var _receiveQueue: Atomic<DispatchQueue?>
    public var receiveQueue: DispatchQueue {
        get { Dependencies.getValueSettingIfNull(&_receiveQueue) { DispatchQueue.global(qos: .default) } }
        set { _receiveQueue.mutate { $0 = newValue } }
    }
    
    public var _mutableGeneralCache: Atomic<MutableGeneralCacheType?>
    public var mutableGeneralCache: Atomic<MutableGeneralCacheType> {
        get {
            Dependencies.getMutableValueSettingIfNull(&_mutableGeneralCache) {
                Dependencies._generalCacheInstanceAccessQueue.sync { Dependencies._generalCacheInstance }
            }
        }
    }
    public var generalCache: GeneralCacheType {
        get {
            Dependencies.getValueSettingIfNull(&_mutableGeneralCache) {
                Dependencies._generalCacheInstanceAccessQueue.sync { Dependencies._generalCacheInstance }
            }
        }
        set {
            guard let mutableValue: MutableGeneralCacheType = newValue as? MutableGeneralCacheType else { return }
            
            _mutableGeneralCache.mutate { $0 = mutableValue }
        }
    }
    
    public var _storage: Atomic<Storage?>
    public var storage: Storage {
        get { Dependencies.getValueSettingIfNull(&_storage) { Storage.shared } }
        set { _storage.mutate { $0 = newValue } }
    }
    
    public var _scheduler: Atomic<ValueObservationScheduler?>
    public var scheduler: ValueObservationScheduler {
        get { Dependencies.getValueSettingIfNull(&_scheduler) { Storage.defaultPublisherScheduler } }
        set { _scheduler.mutate { $0 = newValue } }
    }
    
    public var _standardUserDefaults: Atomic<UserDefaultsType?>
    public var standardUserDefaults: UserDefaultsType {
        get { Dependencies.getValueSettingIfNull(&_standardUserDefaults) { UserDefaults.standard } }
        set { _standardUserDefaults.mutate { $0 = newValue } }
    }
    
    public var _date: Atomic<Date?>
    public var date: Date {
        get { Dependencies.getValueSettingIfNull(&_date) { Date() } }
        set { _date.mutate { $0 = newValue } }
    }
    
    // MARK: - Initialization
    
    public init(
        subscribeQueue: DispatchQueue? = nil,
        receiveQueue: DispatchQueue? = nil,
        generalCache: MutableGeneralCacheType? = nil,
        storage: Storage? = nil,
        scheduler: ValueObservationScheduler? = nil,
        standardUserDefaults: UserDefaultsType? = nil,
        date: Date? = nil
    ) {
        _subscribeQueue = Atomic(subscribeQueue)
        _receiveQueue = Atomic(receiveQueue)
        _mutableGeneralCache = Atomic(generalCache)
        _storage = Atomic(storage)
        _scheduler = Atomic(scheduler)
        _standardUserDefaults = Atomic(standardUserDefaults)
        _date = Atomic(date)
    }
    
    // MARK: - Convenience
    
    public static func getValueSettingIfNull<T>(_ maybeValue: inout Atomic<T?>, _ valueGenerator: () -> T) -> T {
        guard let value: T = maybeValue.wrappedValue else {
            let value: T = valueGenerator()
            maybeValue.mutate { $0 = value }
            return value
        }
        
        return value
    }
    
    public static func getMutableValueSettingIfNull<T>(_ maybeValue: inout Atomic<T?>, _ valueGenerator: () -> T) -> Atomic<T> {
        guard let value: T = maybeValue.wrappedValue else {
            let value: T = valueGenerator()
            maybeValue.mutate { $0 = value }
            return Atomic(value)
        }
        
        return Atomic(value)
    }
}
