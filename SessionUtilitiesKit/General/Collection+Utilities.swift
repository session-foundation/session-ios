// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension Collection where Element == String {
    func withUnsafeCStrArray<R>(
        _ body: (UnsafeBufferPointer<UnsafePointer<CChar>?>) throws -> R
    ) throws -> R {
        let cCharArrays: [[CChar]] = try map { swiftStr in
            guard let cChars = swiftStr.cString(using: .utf8) else {
                throw LibSessionError.invalidCConversion
            }
            
            return cChars
        }
        
        /// Temporary storage for pointers to the C pointers, needs to live until the closure returns
        var temporaryPointerStorage: [UnsafePointer<CChar>?] = []
        temporaryPointerStorage.reserveCapacity(cCharArrays.count)
        
        for cCharArray in cCharArrays {
            /// Get pointer for this specific inner array. The `withUnsafeBufferPointer` scope ends here, but Swift ensures the
            /// underlying data is valid long enough for the pointer to be added to `temporaryPointerStorage` (ARC keeps the
            /// `cCharArrays` alive)
            cCharArray.withUnsafeBufferPointer { bufferPtr in
                temporaryPointerStorage.append(bufferPtr.baseAddress)
            }
        }
        
        /// Get a temporary pointer to `temporaryPointerStorage` which holds valid pointers (or `nil`) for each element,
        /// this array of pointers has a *shallow* scope.
        return try temporaryPointerStorage.withUnsafeBufferPointer { pointersBuffer in
            try body(pointersBuffer)
        }
    }
}

public extension Collection where Element == [UInt8]? {
    func withUnsafeUInt8CArray<R>(
        _ body: (UnsafeBufferPointer<UnsafePointer<UInt8>?>) throws -> R
    ) throws -> R {
        /// Temporary storage for pointers to each inner array's data, needs to live until the closure returns
        var temporaryPointerStorage: [UnsafePointer<UInt8>?] = []
        temporaryPointerStorage.reserveCapacity(self.count) // Pre-allocate space
        
        for element in self {
            guard let array = element else {
                temporaryPointerStorage.append(nil)
                continue
            }
            
            /// Get pointer for this specific inner array. The `withUnsafeBufferPointer` scope ends here, but Swift ensures the
            /// underlying data is valid long enough for the pointer to be added to `temporaryPointerStorage` (ARC keeps the
            /// [UInt8] arrays alive)
            array.withUnsafeBufferPointer { bufferPtr in
                temporaryPointerStorage.append(bufferPtr.baseAddress)
            }
        }
        
        /// Get a temporary pointer to `temporaryPointerStorage` which holds valid pointers (or `nil`) for each element,
        /// this array of pointers has a *shallow* scope.
        return try temporaryPointerStorage.withUnsafeBufferPointer { pointersBuffer in
            try body(pointersBuffer)
        }
    }
}
