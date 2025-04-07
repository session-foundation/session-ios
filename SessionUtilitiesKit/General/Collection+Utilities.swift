// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

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
        
        func getPointers(
            remainingArrays: ArraySlice<[CChar]>,
            collectedPointers: [UnsafePointer<CChar>?]
        ) throws -> R {
            guard let currentArray = remainingArrays.first else {
                return try collectedPointers.withUnsafeBufferPointer { collectedPointersBuffer in
                    try body(collectedPointersBuffer)
                }
            }
            
            return try currentArray.withUnsafeBufferPointer { currentBufferPtr in
                try getPointers(
                    remainingArrays: remainingArrays.dropFirst(),
                    collectedPointers: collectedPointers + [currentBufferPtr.baseAddress]
                )
            }
        }
        
        return try getPointers(remainingArrays: ArraySlice(cCharArrays), collectedPointers: [])
    }
}

public extension Collection where Element == [UInt8]? {
    func withUnsafeUInt8CArray<R>(
        _ body: (UnsafeBufferPointer<UnsafePointer<UInt8>?>) throws -> R
    ) throws -> R {
        func processNext<I: IteratorProtocol>(
            iterator: inout I,
            collectedPointers: [UnsafePointer<UInt8>?]
        ) throws -> R where I.Element == Element {
            if let optionalElement: [UInt8]? = iterator.next() {
                if let array: [UInt8] = optionalElement {
                     return try array.withUnsafeBufferPointer { bufferPtr in
                        try processNext(iterator: &iterator, collectedPointers: collectedPointers + [bufferPtr.baseAddress])
                    }
                }
                
                // It's a nil element in the input collection, add a nil pointer and recurse
                return try processNext(iterator: &iterator, collectedPointers: collectedPointers + [nil])
            } else {
                return try collectedPointers.withUnsafeBufferPointer { pointersBuffer in
                    try body(pointersBuffer)
                }
            }
        }

        var iterator = makeIterator()
        return try processNext(iterator: &iterator, collectedPointers: [])
    }
}
