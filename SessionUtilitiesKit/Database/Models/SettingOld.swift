// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

// MARK: - Setting

public struct SettingOld: Codable, Identifiable, FetchableRecord, PersistableRecord, TableRecord, ColumnExpressible {
    public static var databaseTableName: String { "setting" }
    
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

extension SettingOld {
    // MARK: - Numeric Setting
    
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
    
    // MARK: - String Setting
    
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

// MARK: - Setting Keys

public extension SettingOld {
    protocol Key: RawRepresentable, ExpressibleByStringLiteral, Hashable {
        init(_ rawValue: String)
    }
    
    struct DateKey: Key {
        public let rawValue: String
        public init(_ rawValue: String) { self.rawValue = rawValue }
    }
    
    struct IntKey: Key {
        public let rawValue: String
        public init(_ rawValue: String) { self.rawValue = rawValue }
    }
    
    struct StringKey: Key {
        public let rawValue: String
        public init(_ rawValue: String) { self.rawValue = rawValue }
    }
}

public extension SettingOld.Key {
    init?(rawValue: String) { self.init(rawValue) }
    init(stringLiteral value: String) { self.init(value) }
    init(unicodeScalarLiteral value: String) { self.init(value) }
    init(extendedGraphemeClusterLiteral value: String) { self.init(value) }
}

// MARK: - GRDB Interactions

public extension Database {
    private subscript(key: String) -> SettingOld? {
        get { try? SettingOld.filter(id: key).fetchOne(self) }
        set {
            guard let newValue: SettingOld = newValue else {
                _ = try? SettingOld.filter(id: key).deleteAll(self)
                return
            }
            
            try? newValue.upsert(self)
        }
    }
    
    subscript(key: SettingOld.IntKey) -> Int? {
        get { self[key.rawValue]?.value(as: Int.self) }
        set { self[key.rawValue] = SettingOld(key: key.rawValue, value: newValue) }
    }
    
    subscript(key: SettingOld.StringKey) -> String? {
        get { self[key.rawValue]?.value(as: String.self) }
        set { self[key.rawValue] = SettingOld(key: key.rawValue, value: newValue) }
    }
    
    /// Value will be stored as a timestamp in seconds since 1970
    subscript(key: SettingOld.DateKey) -> Date? {
        get {
            let timestamp: TimeInterval? = self[key.rawValue]?.value(as: TimeInterval.self)
            
            return timestamp.map { Date(timeIntervalSince1970: $0) }
        }
        set {
            self[key.rawValue] = SettingOld(
                key: key.rawValue,
                value: newValue.map { $0.timeIntervalSince1970 }
            )
        }
    }
    
//    func setting(key: SettingOld.IntKey, to newValue: Int?) -> SettingOld? {
//        let result: SettingOld? = SettingOld(key: key.rawValue, value: newValue)
//        self[key.rawValue] = result
//        return result
//    }
//    
//    func setting(key: SettingOld.StringKey, to newValue: String?) -> SettingOld? {
//        let result: SettingOld? = SettingOld(key: key.rawValue, value: newValue)
//        self[key.rawValue] = result
//        return result
//    }
//    
//    /// Value will be stored as a timestamp in seconds since 1970
//    func setting(key: SettingOld.DateKey, to newValue: Date?) -> SettingOld? {
//        let result: SettingOld? = SettingOld(key: key.rawValue, value: newValue.map { $0.timeIntervalSince1970 })
//        self[key.rawValue] = result
//        return result
//    }
}
