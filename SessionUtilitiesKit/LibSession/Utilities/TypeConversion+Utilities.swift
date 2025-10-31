// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtil

// MARK: - String

public extension String {    
    /// Initialize with an optional pointer and a specific length
    init?(pointer: UnsafeRawPointer?, length: Int, encoding: String.Encoding = .utf8) {
        guard
            let pointer: UnsafeRawPointer = pointer,
            let result: String = String(data: Data(bytes: pointer, count: length), encoding: encoding)
        else { return nil }
        
        self = result
    }
}

// MARK: - Array

public extension Array where Element == String {
    init?(cStringArray: UnsafePointer<UnsafePointer<CChar>?>?, count: Int?) {
        /// If `count` was provided but is `0` then accessing the pointer could crash (as it could be bad memory) so just return an empty array
        guard
            let cStringArray: UnsafePointer<UnsafePointer<CChar>?> = cStringArray,
            let count: Int = count
        else { return nil }
        
        self.init()
        self.reserveCapacity(count)
        
        for i in 0..<count {
            if let cStringPtr: UnsafePointer<CChar> = cStringArray[i] {
                self.append(String(cString: cStringPtr))
            }
        }
    }
    
    init?(cStringArray: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, count: Int?) {
        /// If `count` was provided but is `0` then accessing the pointer could crash (as it could be bad memory) so just return an empty array
        guard
            let cStringArray: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> = cStringArray,
            let count: Int = count
        else { return nil }
        
        self.init()
        self.reserveCapacity(count)
        
        for i in 0..<count {
            if let cStringPtr: UnsafeMutablePointer<CChar> = cStringArray[i] {
                self.append(String(cString: cStringPtr))
            }
        }
    }
}

public extension Collection where Element == String {
    func withUnsafeCStrArray<R>(
        _ body: (UnsafeBufferPointer<UnsafePointer<CChar>?>) throws -> R
    ) throws -> R {
        var allocatedBuffers: [UnsafeMutableBufferPointer<CChar>] = []
        allocatedBuffers.reserveCapacity(self.count)
        defer { allocatedBuffers.forEach { $0.deallocate() } }
        
        var pointers: [UnsafePointer<CChar>?] = []
        pointers.reserveCapacity(self.count)
        
        for string in self {
            let utf8: [CChar] = Array(string.utf8CString) /// Includes null terminator
            let buffer = UnsafeMutableBufferPointer<CChar>.allocate(capacity: utf8.count)
            _ = buffer.initialize(from: utf8)
            allocatedBuffers.append(buffer)
            pointers.append(UnsafePointer(buffer.baseAddress))
        }
        
        return try pointers.withUnsafeBufferPointer { buffer in
            try body(buffer)
        }
    }
}

public extension Collection where Element == [UInt8]? {
    func withUnsafeUInt8CArray<R>(
        _ body: (UnsafeBufferPointer<UnsafePointer<UInt8>?>) throws -> R
    ) throws -> R {
        var allocatedBuffers: [UnsafeMutableBufferPointer<UInt8>] = []
        allocatedBuffers.reserveCapacity(self.count)
        defer { allocatedBuffers.forEach { $0.deallocate() } }
        
        var pointers: [UnsafePointer<UInt8>?] = []
        pointers.reserveCapacity(self.count)
        
        for maybeBytes in self {
            if let bytes: [UInt8] = maybeBytes {
                let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: bytes.count)
                _ = buffer.initialize(from: bytes)
                allocatedBuffers.append(buffer)
                pointers.append(UnsafePointer(buffer.baseAddress))
            } else {
                pointers.append(nil)
            }
        }
        
        return try pointers.withUnsafeBufferPointer { buffer in
            try body(buffer)
        }
    }
}

public extension Collection where Element: DataProtocol {
    func withUnsafeSpanOfSpans<Result>(_ body: (UnsafePointer<span_u8>?, Int) throws -> Result) rethrows -> Result {
        var allocatedBuffers: [UnsafeMutableBufferPointer<UInt8>] = []
        allocatedBuffers.reserveCapacity(self.count)
        defer { allocatedBuffers.forEach { $0.deallocate() } }
        
        var spans: [span_u8] = []
        spans.reserveCapacity(self.count)
        
        for data in self {
            let bytes: [UInt8] = Array(data)
            let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: bytes.count)
            _ = buffer.initialize(from: bytes)
            allocatedBuffers.append(buffer)
            
            var span: span_u8 = span_u8()
            span.data = buffer.baseAddress
            span.size = bytes.count
            spans.append(span)
        }
        
        return try spans.withUnsafeBufferPointer { spanBuffer in
            try body(spanBuffer.baseAddress, spanBuffer.count)
        }
    }
}

public extension DataProtocol {
    func withUnsafeSpan<Result>(_ body: (span_u8) throws -> Result) rethrows -> Result {
        try Data(self).withUnsafeBytes { bytes in
            var span: span_u8 = span_u8()
            span.data = UnsafeMutablePointer(mutating: bytes.baseAddress?.assumingMemoryBound(to: UInt8.self))
            span.size = self.count
            
            return try body(span)
        }
    }
}

// MARK: - CAccessible

public protocol CAccessible {}
public extension CAccessible {
    // General types
    
    func get<T>(_ keyPath: KeyPath<Self, T>) -> T { withUnsafePointer(to: self) { $0.get(keyPath) } }
    
    // String variants
    
    func get(_ keyPath: KeyPath<Self, CChar65>) -> String { withUnsafePointer(to: self) { $0.get(keyPath) } }
    func get(_ keyPath: KeyPath<Self, CChar67>) -> String { withUnsafePointer(to: self) { $0.get(keyPath) } }
    func get(_ keyPath: KeyPath<Self, CChar101>) -> String { withUnsafePointer(to: self) { $0.get(keyPath) } }
    func get(_ keyPath: KeyPath<Self, CChar128>) -> String { withUnsafePointer(to: self) { $0.get(keyPath) } }
    func get(_ keyPath: KeyPath<Self, CChar224>) -> String { withUnsafePointer(to: self) { $0.get(keyPath) } }
    func get(_ keyPath: KeyPath<Self, CChar268>) -> String { withUnsafePointer(to: self) { $0.get(keyPath) } }
    
    func get(_ keyPath: KeyPath<Self, CChar65>, nullIfEmpty: Bool = false, explicitLength: Int? = nil) -> String? {
        withUnsafePointer(to: self) { $0.get(keyPath, nullIfEmpty: nullIfEmpty, explicitLength: explicitLength) }
    }
    func get(_ keyPath: KeyPath<Self, CChar67>, nullIfEmpty: Bool = false, explicitLength: Int? = nil) -> String? {
        withUnsafePointer(to: self) { $0.get(keyPath, nullIfEmpty: nullIfEmpty, explicitLength: explicitLength) }
    }
    func get(_ keyPath: KeyPath<Self, CChar101>, nullIfEmpty: Bool = false, explicitLength: Int? = nil) -> String? {
        withUnsafePointer(to: self) { $0.get(keyPath, nullIfEmpty: nullIfEmpty, explicitLength: explicitLength) }
    }
    func get(_ keyPath: KeyPath<Self, CChar128>, nullIfEmpty: Bool = false, explicitLength: Int? = nil) -> String? {
        withUnsafePointer(to: self) { $0.get(keyPath, nullIfEmpty: nullIfEmpty, explicitLength: explicitLength) }
    }
    func get(_ keyPath: KeyPath<Self, CChar224>, nullIfEmpty: Bool = false, explicitLength: Int? = nil) -> String? {
        withUnsafePointer(to: self) { $0.get(keyPath, nullIfEmpty: nullIfEmpty, explicitLength: explicitLength) }
    }
    func get(_ keyPath: KeyPath<Self, CChar268>, nullIfEmpty: Bool = false, explicitLength: Int? = nil) -> String? {
        withUnsafePointer(to: self) { $0.get(keyPath, nullIfEmpty: nullIfEmpty, explicitLength: explicitLength) }
    }
    
    func get(_ keyPath: KeyPath<Self, string8>) -> String {
        withUnsafePointer(to: self) { $0.get(keyPath) }
    }
    
    func get(_ keyPath: KeyPath<Self, string8>, nullIfEmpty: Bool) -> String? {
        withUnsafePointer(to: self) { $0.get(keyPath, nullIfEmpty: nullIfEmpty) }
    }
    
    // Data variants
    
    func get(_ keyPath: KeyPath<Self, CUChar32>) -> Data { withUnsafePointer(to: self) { $0.get(keyPath) } }
    func get(_ keyPath: KeyPath<Self, CUChar32>) -> [UInt8] { withUnsafePointer(to: self) { $0.get(keyPath) } }
    func getHex(_ keyPath: KeyPath<Self, CUChar32>) -> String { withUnsafePointer(to: self) { $0.getHex(keyPath) } }
    func get(_ keyPath: KeyPath<Self, CUChar33>) -> Data { withUnsafePointer(to: self) { $0.get(keyPath) } }
    func get(_ keyPath: KeyPath<Self, CUChar33>) -> [UInt8] { withUnsafePointer(to: self) { $0.get(keyPath) } }
    func getHex(_ keyPath: KeyPath<Self, CUChar33>) -> String { withUnsafePointer(to: self) { $0.getHex(keyPath) } }
    func get(_ keyPath: KeyPath<Self, CUChar64>) -> Data { withUnsafePointer(to: self) { $0.get(keyPath) } }
    func get(_ keyPath: KeyPath<Self, CUChar64>) -> [UInt8] { withUnsafePointer(to: self) { $0.get(keyPath) } }
    func getHex(_ keyPath: KeyPath<Self, CUChar64>) -> String { withUnsafePointer(to: self) { $0.getHex(keyPath) } }
    func get(_ keyPath: KeyPath<Self, CUChar100>) -> Data { withUnsafePointer(to: self) { $0.get(keyPath) } }
    func get(_ keyPath: KeyPath<Self, CUChar100>) -> [UInt8] { withUnsafePointer(to: self) { $0.get(keyPath) } }
    func getHex(_ keyPath: KeyPath<Self, CUChar100>) -> String { withUnsafePointer(to: self) { $0.getHex(keyPath) } }
    func get<T: CTupleWrapper>(_ keyPath: KeyPath<Self, T>) -> Data { withUnsafePointer(to: self) { $0.get(keyPath) } }
    func get<T: CTupleWrapper>(_ keyPath: KeyPath<Self, T>) -> [UInt8] { withUnsafePointer(to: self) { $0.get(keyPath) } }
    func getHex<T: CTupleWrapper>(_ keyPath: KeyPath<Self, T>) -> String { withUnsafePointer(to: self) { $0.getHex(keyPath) } }
    
    func get(_ keyPath: KeyPath<Self, CUChar32>, nullIfEmpty: Bool = false) -> Data? {
        withUnsafePointer(to: self) { $0.get(keyPath, nullIfEmpty: nullIfEmpty) }
    }
    func get(_ keyPath: KeyPath<Self, CUChar32>, nullIfEmpty: Bool = false) -> [UInt8]? {
        withUnsafePointer(to: self) { $0.get(keyPath, nullIfEmpty: nullIfEmpty) }
    }
    func getHex(_ keyPath: KeyPath<Self, CUChar32>, nullIfEmpty: Bool = false) -> String? {
        withUnsafePointer(to: self) { $0.getHex(keyPath, nullIfEmpty: nullIfEmpty) }
    }
    func get(_ keyPath: KeyPath<Self, CUChar33>, nullIfEmpty: Bool = false) -> Data? {
        withUnsafePointer(to: self) { $0.get(keyPath, nullIfEmpty: nullIfEmpty) }
    }
    func get(_ keyPath: KeyPath<Self, CUChar33>, nullIfEmpty: Bool = false) -> [UInt8]? {
        withUnsafePointer(to: self) { $0.get(keyPath, nullIfEmpty: nullIfEmpty) }
    }
    func getHex(_ keyPath: KeyPath<Self, CUChar33>, nullIfEmpty: Bool = false) -> String? {
        withUnsafePointer(to: self) { $0.getHex(keyPath, nullIfEmpty: nullIfEmpty) }
    }
    func get(_ keyPath: KeyPath<Self, CUChar64>, nullIfEmpty: Bool = false) -> Data? {
        withUnsafePointer(to: self) { $0.get(keyPath, nullIfEmpty: nullIfEmpty) }
    }
    func get(_ keyPath: KeyPath<Self, CUChar64>, nullIfEmpty: Bool = false) -> [UInt8]? {
        withUnsafePointer(to: self) { $0.get(keyPath, nullIfEmpty: nullIfEmpty) }
    }
    func getHex(_ keyPath: KeyPath<Self, CUChar64>, nullIfEmpty: Bool = false) -> String? {
        withUnsafePointer(to: self) { $0.getHex(keyPath, nullIfEmpty: nullIfEmpty) }
    }
    func get(_ keyPath: KeyPath<Self, CUChar100>, nullIfEmpty: Bool = false) -> Data? {
        withUnsafePointer(to: self) { $0.get(keyPath, nullIfEmpty: nullIfEmpty) }
    }
    func get(_ keyPath: KeyPath<Self, CUChar100>, nullIfEmpty: Bool = false) -> [UInt8]? {
        withUnsafePointer(to: self) { $0.get(keyPath, nullIfEmpty: nullIfEmpty) }
    }
    func getHex(_ keyPath: KeyPath<Self, CUChar100>, nullIfEmpty: Bool = false) -> String? {
        withUnsafePointer(to: self) { $0.getHex(keyPath, nullIfEmpty: nullIfEmpty) }
    }
    func get<T: CTupleWrapper>(_ keyPath: KeyPath<Self, T>, nullIfEmpty: Bool = false) -> Data? {
        withUnsafePointer(to: self) { $0.get(keyPath, nullIfEmpty: nullIfEmpty) }
    }
    func get<T: CTupleWrapper>(_ keyPath: KeyPath<Self, T>, nullIfEmpty: Bool = false) -> [UInt8]? {
        withUnsafePointer(to: self) { $0.get(keyPath, nullIfEmpty: nullIfEmpty) }
    }
    func getHex<T: CTupleWrapper>(_ keyPath: KeyPath<Self, T>, nullIfEmpty: Bool = false) -> String? {
        withUnsafePointer(to: self) { $0.getHex(keyPath, nullIfEmpty: nullIfEmpty) }
    }
}

// MARK: - CMutable

public protocol CMutable {}
public extension CMutable {
    // General types
    
    mutating func set<T>(_ keyPath: WritableKeyPath<Self, T>, to value: T) {
        withUnsafeMutablePointer(to: &self) { $0.set(keyPath, to: value) }
    }
    
    // Data variants
    
    mutating func set<T: DataProtocol>(_ keyPath: WritableKeyPath<Self, CUChar32>, to value: T?) {
        withUnsafeMutablePointer(to: &self) { $0.set(keyPath, to: value) }
    }
    
    mutating func set<T: DataProtocol>(_ keyPath: WritableKeyPath<Self, CUChar33>, to value: T?) {
        withUnsafeMutablePointer(to: &self) { $0.set(keyPath, to: value) }
    }
    
    mutating func set<T: DataProtocol>(_ keyPath: WritableKeyPath<Self, CUChar64>, to value: T?) {
        withUnsafeMutablePointer(to: &self) { $0.set(keyPath, to: value) }
    }
    
    mutating func set<T: DataProtocol>(_ keyPath: WritableKeyPath<Self, CUChar100>, to value: T?) {
        withUnsafeMutablePointer(to: &self) { $0.set(keyPath, to: value) }
    }
    
    mutating func set<T: CTupleWrapper, D: DataProtocol>(_ keyPath: WritableKeyPath<Self, T>, to value: D?) {
        withUnsafeMutablePointer(to: &self) { $0.set(keyPath, to: value) }
    }
    
    // String variants
    
    mutating func set(_ keyPath: WritableKeyPath<Self, CChar65>, to value: String?) {
        withUnsafeMutablePointer(to: &self) { $0.set(keyPath, to: value) }
    }
    
    mutating func set(_ keyPath: WritableKeyPath<Self, CChar67>, to value: String?) {
        withUnsafeMutablePointer(to: &self) { $0.set(keyPath, to: value) }
    }
    
    mutating func set(_ keyPath: WritableKeyPath<Self, CChar101>, to value: String?) {
        withUnsafeMutablePointer(to: &self) { $0.set(keyPath, to: value) }
    }
    
    mutating func set(_ keyPath: WritableKeyPath<Self, CChar128>, to value: String?) {
        withUnsafeMutablePointer(to: &self) { $0.set(keyPath, to: value) }
    }
    
    mutating func set(_ keyPath: WritableKeyPath<Self, CChar224>, to value: String?) {
        withUnsafeMutablePointer(to: &self) { $0.set(keyPath, to: value) }
    }
    
    mutating func set(_ keyPath: WritableKeyPath<Self, CChar268>, to value: String?) {
        withUnsafeMutablePointer(to: &self) { $0.set(keyPath, to: value) }
    }
}

// MARK: - Pointer Convenience

public protocol ReadablePointer {
    associatedtype Pointee
    var ptr: Pointee { get }
}

extension UnsafePointer: ReadablePointer {
    public var ptr: Pointee { pointee }
}
extension UnsafeMutablePointer: ReadablePointer {
    public var ptr: Pointee { pointee }
}

public extension ReadablePointer {
    // General types
    
    func get<T>(_ keyPath: KeyPath<Pointee, T>) -> T { ptr[keyPath: keyPath] }
    
    // String variants
    
    func get(_ keyPath: KeyPath<Pointee, CChar65>) -> String { getCString(keyPath) }
    func get(_ keyPath: KeyPath<Pointee, CChar67>) -> String { getCString(keyPath) }
    func get(_ keyPath: KeyPath<Pointee, CChar101>) -> String { getCString(keyPath) }
    func get(_ keyPath: KeyPath<Pointee, CChar128>) -> String { getCString(keyPath) }
    func get(_ keyPath: KeyPath<Pointee, CChar224>) -> String { getCString(keyPath) }
    func get(_ keyPath: KeyPath<Pointee, CChar268>) -> String { getCString(keyPath) }
    
    func get(_ keyPath: KeyPath<Pointee, CChar65>, nullIfEmpty: Bool = false, explicitLength: Int? = nil) -> String? {
        getCString(keyPath, nullIfEmpty: nullIfEmpty, explicitLength: explicitLength)
    }
    func get(_ keyPath: KeyPath<Pointee, CChar67>, nullIfEmpty: Bool = false, explicitLength: Int? = nil) -> String? {
        getCString(keyPath, nullIfEmpty: nullIfEmpty, explicitLength: explicitLength)
    }
    func get(_ keyPath: KeyPath<Pointee, CChar101>, nullIfEmpty: Bool = false, explicitLength: Int? = nil) -> String? {
        getCString(keyPath, nullIfEmpty: nullIfEmpty, explicitLength: explicitLength)
    }
    func get(_ keyPath: KeyPath<Pointee, CChar128>, nullIfEmpty: Bool = false, explicitLength: Int? = nil) -> String? {
        getCString(keyPath, nullIfEmpty: nullIfEmpty, explicitLength: explicitLength)
    }
    func get(_ keyPath: KeyPath<Pointee, CChar224>, nullIfEmpty: Bool = false, explicitLength: Int? = nil) -> String? {
        getCString(keyPath, nullIfEmpty: nullIfEmpty, explicitLength: explicitLength)
    }
    func get(_ keyPath: KeyPath<Pointee, CChar268>, nullIfEmpty: Bool = false, explicitLength: Int? = nil) -> String? {
        getCString(keyPath, nullIfEmpty: nullIfEmpty, explicitLength: explicitLength)
    }
    
    func get(_ keyPath: KeyPath<Pointee, string8>) -> String {
        getCString(keyPath)
    }
    
    func get(_ keyPath: KeyPath<Pointee, string8>, nullIfEmpty: Bool) -> String? {
        getCString(keyPath, nullIfEmpty: nullIfEmpty)
    }
    
    // Data variants
    
    func get(_ keyPath: KeyPath<Pointee, CUChar32>) -> Data { getData(keyPath) }
    func get(_ keyPath: KeyPath<Pointee, CUChar32>) -> [UInt8] { Array(getData(keyPath)) }
    func getHex(_ keyPath: KeyPath<Pointee, CUChar32>) -> String { getData(keyPath).toHexString() }
    func get(_ keyPath: KeyPath<Pointee, CUChar33>) -> Data { getData(keyPath) }
    func get(_ keyPath: KeyPath<Pointee, CUChar33>) -> [UInt8] { Array(getData(keyPath)) }
    func getHex(_ keyPath: KeyPath<Pointee, CUChar33>) -> String { getData(keyPath).toHexString() }
    func get(_ keyPath: KeyPath<Pointee, CUChar64>) -> Data { getData(keyPath) }
    func get(_ keyPath: KeyPath<Pointee, CUChar64>) -> [UInt8] { Array(getData(keyPath)) }
    func getHex(_ keyPath: KeyPath<Pointee, CUChar64>) -> String { getData(keyPath).toHexString() }
    func get(_ keyPath: KeyPath<Pointee, CUChar100>) -> Data { getData(keyPath) }
    func get(_ keyPath: KeyPath<Pointee, CUChar100>) -> [UInt8] { Array(getData(keyPath)) }
    func getHex(_ keyPath: KeyPath<Pointee, CUChar100>) -> String { getData(keyPath).toHexString() }
    
    func get<T: CTupleWrapper>(_ keyPath: KeyPath<Pointee, T>) -> Data { getData(keyPath) }
    func get<T: CTupleWrapper>(_ keyPath: KeyPath<Pointee, T>) -> [UInt8] { Array(getData(keyPath)) }
    func getHex<T: CTupleWrapper>(_ keyPath: KeyPath<Pointee, T>) -> String { getData(keyPath).toHexString() }
    
    func get(_ keyPath: KeyPath<Pointee, CUChar32>, nullIfEmpty: Bool = false) -> Data? {
        getData(keyPath, nullIfEmpty: nullIfEmpty)
    }
    func get(_ keyPath: KeyPath<Pointee, CUChar32>, nullIfEmpty: Bool = false) -> [UInt8]? {
        getData(keyPath, nullIfEmpty: nullIfEmpty).map { Array($0) }
    }
    func getHex(_ keyPath: KeyPath<Pointee, CUChar32>, nullIfEmpty: Bool = false) -> String? {
        getData(keyPath, nullIfEmpty: nullIfEmpty).map { $0.toHexString() }
    }
    func get(_ keyPath: KeyPath<Pointee, CUChar33>, nullIfEmpty: Bool = false) -> Data? {
        getData(keyPath, nullIfEmpty: nullIfEmpty)
    }
    func get(_ keyPath: KeyPath<Pointee, CUChar33>, nullIfEmpty: Bool = false) -> [UInt8]? {
        getData(keyPath, nullIfEmpty: nullIfEmpty).map { Array($0) }
    }
    func getHex(_ keyPath: KeyPath<Pointee, CUChar33>, nullIfEmpty: Bool = false) -> String? {
        getData(keyPath, nullIfEmpty: nullIfEmpty).map { $0.toHexString() }
    }
    func get(_ keyPath: KeyPath<Pointee, CUChar64>, nullIfEmpty: Bool = false) -> Data? {
        getData(keyPath, nullIfEmpty: nullIfEmpty)
    }
    func get(_ keyPath: KeyPath<Pointee, CUChar64>, nullIfEmpty: Bool = false) -> [UInt8]? {
        getData(keyPath, nullIfEmpty: nullIfEmpty).map { Array($0) }
    }
    func getHex(_ keyPath: KeyPath<Pointee, CUChar64>, nullIfEmpty: Bool = false) -> String? {
        getData(keyPath, nullIfEmpty: nullIfEmpty).map { $0.toHexString() }
    }
    func get(_ keyPath: KeyPath<Pointee, CUChar100>, nullIfEmpty: Bool = false) -> Data? {
        getData(keyPath, nullIfEmpty: nullIfEmpty)
    }
    func get(_ keyPath: KeyPath<Pointee, CUChar100>, nullIfEmpty: Bool = false) -> [UInt8]? {
        getData(keyPath, nullIfEmpty: nullIfEmpty).map { Array($0) }
    }
    func getHex(_ keyPath: KeyPath<Pointee, CUChar100>, nullIfEmpty: Bool = false) -> String? {
        getData(keyPath, nullIfEmpty: nullIfEmpty).map { $0.toHexString() }
    }
    func get<T: CTupleWrapper>(_ keyPath: KeyPath<Pointee, T>, nullIfEmpty: Bool = false) -> Data? {
        getData(keyPath, nullIfEmpty: nullIfEmpty)
    }
    func get<T: CTupleWrapper>(_ keyPath: KeyPath<Pointee, T>, nullIfEmpty: Bool = false) -> [UInt8]? {
        getData(keyPath, nullIfEmpty: nullIfEmpty).map { Array($0) }
    }
    func getHex<T: CTupleWrapper>(_ keyPath: KeyPath<Pointee, T>, nullIfEmpty: Bool = false) -> String? {
        getData(keyPath, nullIfEmpty: nullIfEmpty).map { $0.toHexString() }
    }
}

public extension UnsafeMutablePointer {
    // General types
    
    func set<T>(_ keyPath: WritableKeyPath<Pointee, T>, to value: T) {
        var mutablePointee: Pointee = pointee
        mutablePointee[keyPath: keyPath] = value
        pointee = mutablePointee
    }
    
    // String variants
    
    func set(_ keyPath: WritableKeyPath<Pointee, CChar65>, to value: String?) { setCString(keyPath, value) }
    func set(_ keyPath: WritableKeyPath<Pointee, CChar67>, to value: String?) { setCString(keyPath, value) }
    func set(_ keyPath: WritableKeyPath<Pointee, CChar101>, to value: String?) { setCString(keyPath, value) }
    func set(_ keyPath: WritableKeyPath<Pointee, CChar128>, to value: String?) { setCString(keyPath, value) }
    func set(_ keyPath: WritableKeyPath<Pointee, CChar224>, to value: String?) { setCString(keyPath, value) }
    func set(_ keyPath: WritableKeyPath<Pointee, CChar268>, to value: String?) { setCString(keyPath, value) }
    
    // Data variants
    
    func set<T: DataProtocol>(_ keyPath: WritableKeyPath<Pointee, CUChar32>, to value: T?) {
        setData(keyPath, value.map { Data($0) })
    }
    
    func set<T: DataProtocol>(_ keyPath: WritableKeyPath<Pointee, CUChar33>, to value: T?) {
        setData(keyPath, value.map { Data($0) })
    }
    
    func set<T: DataProtocol>(_ keyPath: WritableKeyPath<Pointee, CUChar64>, to value: T?) {
        setData(keyPath, value.map { Data($0) })
    }
    
    func set<T: DataProtocol>(_ keyPath: WritableKeyPath<Pointee, CUChar100>, to value: T?) {
        setData(keyPath, value.map { Data($0) })
    }
    
    func set<T: CTupleWrapper, D: DataProtocol>(_ keyPath: WritableKeyPath<Pointee, T>, to value: D?) {
        setData(keyPath, value.map { Data($0) })
    }
}

// MARK: - Internal Logic

private extension ReadablePointer {
    func _getData<T>(_ byteArray: T) -> Data {
        return withUnsafeBytes(of: byteArray) { Data($0) }
    }
    
    func _getData<T>(_ byteArray: T, nullIfEmpty: Bool) -> Data? {
        let result: Data = _getData(byteArray)
        
        return (!nullIfEmpty || result.contains(where: { $0 != 0 }) ? result : nil)
    }
    
    func _string<T>(from value: T, explicitLength: Int? = nil) -> String {
        withUnsafeBytes(of: value) { rawBufferPointer in
            guard let buffer = rawBufferPointer.baseAddress?.assumingMemoryBound(to: CChar.self) else {
                return ""
            }
            
            if let length: Int = explicitLength {
                return (String(pointer: buffer, length: length) ?? "")
            }
            
            /// If we weren't given an explicit length then assume the string is null-terminated
            return String(cString: buffer)
        }
    }
    
    func getData<T>(_ keyPath: KeyPath<Pointee, T>) -> Data {
        return _getData(ptr[keyPath: keyPath])
    }
    
    func getData<T>(_ keyPath: KeyPath<Pointee, T>, nullIfEmpty: Bool) -> Data? {
        return _getData(ptr[keyPath: keyPath], nullIfEmpty: nullIfEmpty)
    }
    
    func getData<T: CTupleWrapper>(_ keyPath: KeyPath<Pointee, T>) -> Data {
        return _getData(ptr[keyPath: keyPath].data)
    }
    
    func getData<T: CTupleWrapper>(_ keyPath: KeyPath<Pointee, T>, nullIfEmpty: Bool) -> Data? {
        return _getData(ptr[keyPath: keyPath].data, nullIfEmpty: nullIfEmpty)
    }
    
    func getCString<T>(_ keyPath: KeyPath<Pointee, T>) -> String {
        return _string(from: ptr[keyPath: keyPath])
    }
    
    func getCString<T>(_ keyPath: KeyPath<Pointee, T>, nullIfEmpty: Bool, explicitLength: Int?) -> String? {
        let result: String = _string(from: ptr[keyPath: keyPath], explicitLength: explicitLength)
        
        return (!nullIfEmpty || !result.isEmpty ? result : nil)
    }
    
    func getCString(_ keyPath: KeyPath<Pointee, string8>) -> String {
        let stringPtr: string8 = ptr[keyPath: keyPath]
        
        return (String(pointer: stringPtr.data, length: stringPtr.size) ?? "")
    }
    
    func getCString(_ keyPath: KeyPath<Pointee, string8>, nullIfEmpty: Bool) -> String? {
        let stringPtr: string8 = ptr[keyPath: keyPath]
        let result: String = (String(pointer: stringPtr.data, length: stringPtr.size) ?? "")
        
        return (!nullIfEmpty || !result.isEmpty ? result : nil)
    }
}

private extension UnsafeMutablePointer {
    private func setData<T>(_ keyPath: WritableKeyPath<Pointee, T>, _ value: Data?) {
        var mutableSelf = pointee
        withUnsafeMutableBytes(of: &mutableSelf[keyPath: keyPath]) { rawBufferPointer in
            rawBufferPointer.initializeMemory(as: UInt8.self, repeating: 0)
            
            if
                let value: Data = value,
                let buffer = rawBufferPointer.baseAddress?.assumingMemoryBound(to: UInt8.self)
            {
                if value.count > rawBufferPointer.count {
                    Log.warn("Setting \(keyPath) to data with \(value.count) length, expected: \(rawBufferPointer.count), value will be truncated.")
                }
                
                let copyCount: Int = min(rawBufferPointer.count, value.count)
                value.copyBytes(to: buffer, count: copyCount)
            }
        }
        pointee = mutableSelf
    }
    
    private func setCString<T>(_ keyPath: WritableKeyPath<Pointee, T>, _ value: String?) {
        var mutableSelf = pointee
        withUnsafeMutableBytes(of: &mutableSelf[keyPath: keyPath]) { rawBufferPointer in
            rawBufferPointer.initializeMemory(as: UInt8.self, repeating: 0)
            
            if
                let value: String = value,
                let buffer = rawBufferPointer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                let cData: Data = value.data(using: .utf8)
            {
                let copyCount: Int = min(rawBufferPointer.count - 1, cData.count)
                cData.copyBytes(to: buffer, count: copyCount)
            }
        }
        pointee = mutableSelf
    }
}

// MARK: - Explicit C Struct Types

public protocol CTupleWrapper {
    associatedtype TupleType
    var data: TupleType { get set }
}

extension bytes32: CTupleWrapper {
    public typealias TupleType = CUChar32
}

extension bytes33: CTupleWrapper {
    public typealias TupleType = CUChar33
}

extension bytes64: CTupleWrapper {
    public typealias TupleType = CUChar64
}

// MARK: - Fixed Length Types

public typealias CUChar32 = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8
)

public typealias CUChar33 = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8
)

public typealias CUChar64 = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8
)

public typealias CUChar100 = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

public typealias CChar65 = (
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar
)

public typealias CChar67 = (
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar
)

public typealias CChar101 = (
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar
)

public typealias CChar128 = (
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar
)

public typealias CChar224 = (
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar
)

public typealias CChar268 = (
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar
)
