// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

public struct KeyValueStore: Codable, Identifiable, FetchableRecord, PersistableRecord, TableRecord, ColumnExpressible {
    public static var databaseTableName: String { "keyValueStore" }
    
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case key
        case value
    }
    
    public var id: String { key }
    public var rawValue: Data { value }
    
    let key: String
    let value: Data
}

extension KeyValueStore {
    // MARK: - Numeric
    
    fileprivate init?<T: Numeric>(key: String, value: T?) {
        guard var value: T = value else { return nil }
        
        self.key = key
        self.value = withUnsafeBytes(of: &value) { Data($0) }
    }
    
    fileprivate func value<T: Numeric>(as type: T.Type) -> T? {
        return value.withUnsafeBytes {
            $0.loadUnaligned(as: T.self)
        }
    }
    
    // MARK: - Bool Setting
    
    fileprivate init?(key: String, value: Bool?) {
        guard var value: Bool = value else { return nil }
        
        self.key = key
        self.value = withUnsafeBytes(of: &value) { Data($0) }
    }
    
    public func unsafeValue(as type: Bool.Type) -> Bool? {
        return value.withUnsafeBytes {
            $0.loadUnaligned(as: Bool.self)
        }
    }
    
    // MARK: - String
    
    fileprivate init?(key: String, value: String?) {
        guard
            let value: String = value,
            let valueData: Data = value.data(using: .utf8)
        else { return nil }
        
        self.key = key
        self.value = valueData
    }
    
    fileprivate func value(as type: String.Type) -> String? {
        return String(data: value, encoding: .utf8)
    }
}

// MARK: - Keys

public extension KeyValueStore {
    struct BoolKey: RawRepresentable, ExpressibleByStringLiteral, Hashable {
        public let rawValue: String
        
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public init?(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { self.init(value) }
        public init(unicodeScalarLiteral value: String) { self.init(value) }
        public init(extendedGraphemeClusterLiteral value: String) { self.init(value) }
    }
    
    struct DateKey: RawRepresentable, ExpressibleByStringLiteral, Hashable {
        public let rawValue: String
        
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public init?(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { self.init(value) }
        public init(unicodeScalarLiteral value: String) { self.init(value) }
        public init(extendedGraphemeClusterLiteral value: String) { self.init(value) }
    }
    
    struct DoubleKey: RawRepresentable, ExpressibleByStringLiteral, Hashable {
        public let rawValue: String
        
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public init?(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { self.init(value) }
        public init(unicodeScalarLiteral value: String) { self.init(value) }
        public init(extendedGraphemeClusterLiteral value: String) { self.init(value) }
    }
    
    struct IntKey: RawRepresentable, ExpressibleByStringLiteral, Hashable {
        public let rawValue: String
        
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public init?(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { self.init(value) }
        public init(unicodeScalarLiteral value: String) { self.init(value) }
        public init(extendedGraphemeClusterLiteral value: String) { self.init(value) }
    }
    
    struct Int64Key: RawRepresentable, ExpressibleByStringLiteral, Hashable {
        public let rawValue: String
        
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public init?(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { self.init(value) }
        public init(unicodeScalarLiteral value: String) { self.init(value) }
        public init(extendedGraphemeClusterLiteral value: String) { self.init(value) }
    }
    
    struct StringKey: RawRepresentable, ExpressibleByStringLiteral, Hashable {
        public let rawValue: String
        
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public init?(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { self.init(value) }
        public init(unicodeScalarLiteral value: String) { self.init(value) }
        public init(extendedGraphemeClusterLiteral value: String) { self.init(value) }
    }
    
    struct EnumKey: RawRepresentable, ExpressibleByStringLiteral, Hashable {
        public let rawValue: String
        
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public init?(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { self.init(value) }
        public init(unicodeScalarLiteral value: String) { self.init(value) }
        public init(extendedGraphemeClusterLiteral value: String) { self.init(value) }
    }
}

// MARK: - GRDB Interactions

public extension ObservingDatabase {
    @discardableResult func unsafeSet<T: Numeric>(key: String, value: T?) -> KeyValueStore? {
        guard let value: T = value else {
            _ = try? KeyValueStore.filter(id: key).deleteAll(self)
            return nil
        }
        
        return try? KeyValueStore(key: key, value: value)?.upserted(self)
    }
    
    private subscript(key: String) -> KeyValueStore? {
        get { try? KeyValueStore.filter(id: key).fetchOne(self) }
        set {
            guard let newValue: KeyValueStore = newValue else {
                _ = try? KeyValueStore.filter(id: key).deleteAll(self)
                return
            }
            
            try? newValue.upsert(self)
        }
    }
    
    subscript(key: KeyValueStore.BoolKey) -> Bool {
        get {
            // Default to false if it doesn't exist
            (self[key.rawValue]?.unsafeValue(as: Bool.self) ?? false)
        }
        set { self[key.rawValue] = KeyValueStore(key: key.rawValue, value: newValue) }
    }
    
    subscript(key: KeyValueStore.DoubleKey) -> Double? {
        get { self[key.rawValue]?.value(as: Double.self) }
        set { self[key.rawValue] = KeyValueStore(key: key.rawValue, value: newValue) }
    }
    
    subscript(key: KeyValueStore.IntKey) -> Int? {
        get { self[key.rawValue]?.value(as: Int.self) }
        set { self[key.rawValue] = KeyValueStore(key: key.rawValue, value: newValue) }
    }
    
    subscript(key: KeyValueStore.Int64Key) -> Int64? {
        get { self[key.rawValue]?.value(as: Int64.self) }
        set { self[key.rawValue] = KeyValueStore(key: key.rawValue, value: newValue) }
    }
    
    subscript(key: KeyValueStore.StringKey) -> String? {
        get { self[key.rawValue]?.value(as: String.self) }
        set { self[key.rawValue] = KeyValueStore(key: key.rawValue, value: newValue) }
    }
    
    subscript<T: RawRepresentable>(key: KeyValueStore.EnumKey) -> T? where T.RawValue == Int {
        get {
            guard let rawValue: Int = self[key.rawValue]?.value(as: Int.self) else {
                return nil
            }
            
            return T(rawValue: rawValue)
        }
        set { self[key.rawValue] = KeyValueStore(key: key.rawValue, value: newValue?.rawValue) }
    }
    
    subscript<T: RawRepresentable>(key: KeyValueStore.EnumKey) -> T? where T.RawValue == String {
        get {
            guard let rawValue: String = self[key.rawValue]?.value(as: String.self) else {
                return nil
            }
            
            return T(rawValue: rawValue)
        }
        set { self[key.rawValue] = KeyValueStore(key: key.rawValue, value: newValue?.rawValue) }
    }
    
    /// Value will be stored as a timestamp in seconds since 1970
    subscript(key: KeyValueStore.DateKey) -> Date? {
        get {
            let timestamp: TimeInterval? = self[key.rawValue]?.value(as: TimeInterval.self)
            
            return timestamp.map { Date(timeIntervalSince1970: $0) }
        }
        set {
            self[key.rawValue] = KeyValueStore(
                key: key.rawValue,
                value: newValue.map { $0.timeIntervalSince1970 }
            )
        }
    }
    
    func setting(key: KeyValueStore.BoolKey, to newValue: Bool) -> KeyValueStore? {
        let result: KeyValueStore? = KeyValueStore(key: key.rawValue, value: newValue)
        self[key.rawValue] = result
        return result
    }
    
    func setting(key: KeyValueStore.DoubleKey, to newValue: Double?) -> KeyValueStore? {
        let result: KeyValueStore? = KeyValueStore(key: key.rawValue, value: newValue)
        self[key.rawValue] = result
        return result
    }
    
    func setting(key: KeyValueStore.IntKey, to newValue: Int?) -> KeyValueStore? {
        let result: KeyValueStore? = KeyValueStore(key: key.rawValue, value: newValue)
        self[key.rawValue] = result
        return result
    }
    
    func setting(key: KeyValueStore.Int64Key, to newValue: Int64?) -> KeyValueStore? {
        let result: KeyValueStore? = KeyValueStore(key: key.rawValue, value: newValue)
        self[key.rawValue] = result
        return result
    }
    
    func setting(key: KeyValueStore.StringKey, to newValue: String?) -> KeyValueStore? {
        let result: KeyValueStore? = KeyValueStore(key: key.rawValue, value: newValue)
        self[key.rawValue] = result
        return result
    }
    
    func setting<T: RawRepresentable>(key: KeyValueStore.EnumKey, to newValue: T?) -> KeyValueStore? where T.RawValue == Int {
        let result: KeyValueStore? = KeyValueStore(key: key.rawValue, value: newValue?.rawValue)
        self[key.rawValue] = result
        return result
    }
    
    func setting<T: RawRepresentable>(key: KeyValueStore.EnumKey, to newValue: T?) -> KeyValueStore? where T.RawValue == String {
        let result: KeyValueStore? = KeyValueStore(key: key.rawValue, value: newValue?.rawValue)
        self[key.rawValue] = result
        return result
    }
    
    /// Value will be stored as a timestamp in seconds since 1970
    func setting(key: KeyValueStore.DateKey, to newValue: Date?) -> KeyValueStore? {
        let result: KeyValueStore? = KeyValueStore(key: key.rawValue, value: newValue.map { $0.timeIntervalSince1970 })
        self[key.rawValue] = result
        return result
    }
}
