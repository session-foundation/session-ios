// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

extension Collection {
    public subscript(ifValid index: Index) -> Iterator.Element? {
        return self.indices.contains(index) ? self[index] : nil
    }
}

public extension Collection where Element == [CChar] {
    /// This creates an array of UnsafePointer types to access data of the C strings in memory. This array provides no automated
    /// memory management of it's children so after use you are responsible for handling the life cycle of the child elements and
    /// need to call `deallocate()` on each child.
    func unsafeCopy() -> [UnsafePointer<CChar>?] {
        return self.map { value in
            let copy = UnsafeMutableBufferPointer<CChar>.allocate(capacity: value.count)
            _ = copy.initialize(from: value)
            return UnsafePointer(copy.baseAddress)
        }
    }
}
