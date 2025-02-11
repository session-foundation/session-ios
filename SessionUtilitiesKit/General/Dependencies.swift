// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

public class Dependencies {
    @ThreadSafeObject private var cachedStorage: Storage?
    public var storage: Storage {
        get { Dependencies.getValueSettingIfNull(&_cachedStorage) { Storage.shared } }
        set { _cachedStorage.set(to: newValue) }
    }
    
    @ThreadSafeObject private var cachedNetwork: NetworkType?
    public var network: NetworkType {
        get { Dependencies.getValueSettingIfNull(&_cachedNetwork) { Network() } }
        set { _cachedNetwork.set(to: newValue) }
    }
    
    @ThreadSafeObject private var cachedCrypto: CryptoType?
    public var crypto: CryptoType {
        get { Dependencies.getValueSettingIfNull(&_cachedCrypto) { Crypto() } }
        set { _cachedCrypto.set(to: newValue) }
    }
    
    @ThreadSafeObject private var cachedStandardUserDefaults: UserDefaultsType?
    public var standardUserDefaults: UserDefaultsType {
        get { Dependencies.getValueSettingIfNull(&_cachedStandardUserDefaults) { UserDefaults.standard } }
        set { _cachedStandardUserDefaults.set(to: newValue) }
    }
    
    private var _caches: CachesType
    public var caches: CachesType {
        get { _caches }
        set { _caches = newValue }
    }
    
    @ThreadSafeObject private var cachedJobRunner: JobRunnerType?
    public var jobRunner: JobRunnerType {
        get { Dependencies.getValueSettingIfNull(&_cachedJobRunner) { JobRunner.instance } }
        set { _cachedJobRunner.set(to: newValue) }
    }
    
    @ThreadSafeObject private var cachedScheduler: ValueObservationScheduler?
    public var scheduler: ValueObservationScheduler {
        get { Dependencies.getValueSettingIfNull(&_cachedScheduler) { Storage.defaultPublisherScheduler } }
        set { _cachedScheduler.set(to: newValue) }
    }
    
    @ThreadSafe private var cachedDateNow: Date?
    public var dateNow: Date {
        get { (cachedDateNow ?? Date()) }
        set { cachedDateNow = newValue }
    }
    
    @ThreadSafe private var cachedFixedTime: Int?
    public var fixedTime: Int {
        get { (cachedFixedTime ?? 0) }
        set { cachedFixedTime = newValue  }
    }
    
    @ThreadSafe private var cachedForceSynchronous: Bool
    public var forceSynchronous: Bool {
        get { cachedForceSynchronous }
        set { cachedForceSynchronous = newValue }
    }
    
    public var asyncExecutions: [Int: [() -> Void]] = [:]
    
    // MARK: - Initialization
    
    public init(
        storage: Storage? = nil,
        network: NetworkType? = nil,
        crypto: CryptoType? = nil,
        standardUserDefaults: UserDefaultsType? = nil,
        caches: CachesType = Caches(),
        jobRunner: JobRunnerType? = nil,
        scheduler: ValueObservationScheduler? = nil,
        dateNow: Date? = nil,
        fixedTime: Int? = nil,
        forceSynchronous: Bool = false
    ) {
        _cachedStorage = ThreadSafeObject(storage)
        _cachedNetwork = ThreadSafeObject(network)
        _cachedCrypto = ThreadSafeObject(crypto)
        _cachedStandardUserDefaults = ThreadSafeObject(standardUserDefaults)
        _caches = caches
        _cachedJobRunner = ThreadSafeObject(jobRunner)
        _cachedScheduler = ThreadSafeObject(scheduler)
        _cachedDateNow = ThreadSafe(dateNow)
        _cachedFixedTime = ThreadSafe(fixedTime)
        _cachedForceSynchronous = ThreadSafe(forceSynchronous)
    }
    
    // MARK: - Convenience
    
    private static func getValueSettingIfNull<T>(_ maybeValue: inout ThreadSafeObject<Optional<T>>, _ valueGenerator: () -> T) -> T {
        guard let value: T = maybeValue.wrappedValue else {
            let value: T = valueGenerator()
            maybeValue.set(to: value)
            return value
        }
        
        return value
    }
    
#if DEBUG
    public func stepForwardInTime() {
        let targetTime: Int = (fixedTime + 1)
        fixedTime = targetTime
        
        if let currentDate: Date = _cachedDateNow.wrappedValue {
            dateNow = Date(timeIntervalSince1970: currentDate.timeIntervalSince1970 + 1)
        }
        
        // Run and clear any executions which should run at the target time
        let targetKeys: [Int] = asyncExecutions.keys
            .filter { $0 <= targetTime }
        targetKeys.forEach { key in
            asyncExecutions[key]?.forEach { $0() }
            asyncExecutions[key] = nil
        }
    }
#endif
    
    // MARK: - Random Access Functions
    
    public func randomElement<T: Collection>(_ collection: T) -> T.Element? {
        return collection.randomElement()
    }
    
    public func randomElement<T>(_ elements: Set<T>) -> T? {
        return elements.randomElement()
    }
    
    public func popRandomElement<T>(_ elements: inout Set<T>) -> T? {
        return elements.popRandomElement()
    }
}
