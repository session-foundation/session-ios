// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

// MARK: - String

public extension String {
    var cArray: [CChar] { [UInt8](self.utf8).map { CChar(bitPattern: $0) } }
    
    /// Initialize with an optional pointer and a specific length
    init?(pointer: UnsafeRawPointer?, length: Int, encoding: String.Encoding = .utf8) {
        guard
            let pointer: UnsafeRawPointer = pointer,
            let result: String = String(data: Data(bytes: pointer, count: length), encoding: encoding)
        else { return nil }
        
        self = result
    }
    
    init?<T>(
        libSessionVal: T,
        nullTerminated: Bool = true,
        nullIfEmpty: Bool = false
    ) {
        let result: String = {
            guard !nullTerminated else {
                return String(cString: withUnsafeBytes(of: libSessionVal) { [UInt8]($0) })
            }
            
            return String(
                data: Data(libSessionVal: libSessionVal, count: MemoryLayout<T>.size),
                encoding: .utf8
            )
            .defaulting(to: "")
        }()
        
        guard !nullIfEmpty || !result.isEmpty else { return nil }
        
        self = result
    }
    
    func toLibSession<T>() -> T {
        let targetSize: Int = MemoryLayout<T>.stride
        let result: UnsafeMutableRawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: targetSize,
            alignment: MemoryLayout<T>.alignment
        )
        self.utf8CString.withUnsafeBytes { result.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        
        return result.withMemoryRebound(to: T.self, capacity: targetSize) { $0.pointee }
    }
}

public extension Optional<String> {
    func toLibSession<T>() -> T {
        switch self {
            case .some(let value): return value.toLibSession()
            case .none: return "".toLibSession()
        }
    }
}

// MARK: - Data

public extension Data {
    var cArray: [UInt8] { [UInt8](self) }
    
    init<T>(libSessionVal: T, count: Int) {
        self = Data(
            bytes: Swift.withUnsafeBytes(of: libSessionVal) { [UInt8]($0) },
            count: count
        )
    }
    
    func toLibSession<T>() -> T {
        let targetSize: Int = MemoryLayout<T>.stride
        let result: UnsafeMutableRawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: targetSize,
            alignment: MemoryLayout<T>.alignment
        )
        self.withUnsafeBytes { result.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }

        return result.withMemoryRebound(to: T.self, capacity: targetSize) { $0.pointee }
    }
}

public extension Optional<Data> {
    func toLibSession<T>() -> T {
        switch self {
            case .some(let value): return value.toLibSession()
            case .none: return Data().toLibSession()
        }
    }
}

// MARK: - Array

public extension Array where Element == CChar {
    func nullTerminated() -> [Element] {
        guard self.last != CChar(0) else { return self }
        
        return self.appending(CChar(0))
    }
}
