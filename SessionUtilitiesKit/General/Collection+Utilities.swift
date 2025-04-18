// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension Collection where Element == String {
    func withUnsafeCStrArray<R>(
        _ body: (UnsafeBufferPointer<UnsafePointer<CChar>?>) throws -> R
    ) throws -> R {
        let pointerArray = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: self.count)
        var allocatedCStrings: [UnsafeMutablePointer<CChar>?] = []
        allocatedCStrings.reserveCapacity(self.count)
        defer {
            for ptr in allocatedCStrings {
                free(ptr)   /// Need to use `free` for memory allocated by `strdup`
            }
            pointerArray.deallocate()
        }
        
        var currentPtr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> = pointerArray
        for element in self {
            /// `strdup` allocates memory and copies the C string (inc. null terminator), it returns NULL on allocation failure.
            guard let cString: UnsafeMutablePointer<CChar> = strdup(element) else {
                throw LibSessionError.invalidCConversion
            }
            
            allocatedCStrings.append(cString)  /// Track for cleanup
            currentPtr.pointee = cString       /// Store pointer in the array
            currentPtr += 1                    /// Move to next slot in pointer array
        }
        
        let mutableBuffer = UnsafeBufferPointer(start: pointerArray, count: self.count)
        
        return try mutableBuffer.withMemoryRebound(to: UnsafePointer<CChar>?.self) { immutableBuffer in
            try body(immutableBuffer)
        }
    }
}

public extension Collection where Element == [UInt8]? {
    func withUnsafeUInt8CArray<R>(
        _ body: (UnsafeBufferPointer<UnsafePointer<UInt8>?>) throws -> R
    ) throws -> R {
        let pointerArray = UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>.allocate(capacity: self.count)
        var allocatedByteArrays: [UnsafeMutableRawPointer?] = []
        allocatedByteArrays.reserveCapacity(self.count)

        defer {
            for ptr in allocatedByteArrays {
                free(ptr) /// Need to use `free` for memory allocated by `malloc`
            }
            
            pointerArray.deallocate()
        }

        var currentPtr: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?> = pointerArray
        for maybeBytes in self {
            if let bytes = maybeBytes {
                guard let allocatedMemory: UnsafeMutableRawPointer = malloc(bytes.count) else {
                    throw LibSessionError.invalidCConversion
                }
                
                allocatedByteArrays.append(allocatedMemory) /// Track for cleanup
                memcpy(allocatedMemory, bytes, bytes.count) /// Copy bytes into the allocated memory
                currentPtr.pointee = allocatedMemory.assumingMemoryBound(to: UInt8.self) /// Store in array
            } else {
                currentPtr.pointee = nil /// Store nil in array
            }
            currentPtr += 1 /// Move to next slot in pointer array
        }

        let mutableBuffer = UnsafeBufferPointer(start: pointerArray, count: self.count)

        return try mutableBuffer.withMemoryRebound(to: UnsafePointer<UInt8>?.self) { immutableBuffer in
            try body(immutableBuffer)
        }
    }
}
