// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

public extension Array where Element: CustomStringConvertible {
    var prettifiedDescription: String {
        return "[ " + map { $0.description }.joined(separator: ", ") + " ]"
    }
}

public extension Array {
    func appending(_ other: Element?) -> [Element] {
        guard let other: Element = other else { return self }
        
        var updatedArray: [Element] = self
        updatedArray.append(other)
        return updatedArray
    }
    
    func appending(contentsOf other: [Element]?) -> [Element] {
        guard let other: [Element] = other else { return self }
        
        var updatedArray: [Element] = self
        updatedArray.append(contentsOf: other)
        return updatedArray
    }
    
    func removing(index: Int) -> [Element] {
        var updatedArray: [Element] = self
        updatedArray.remove(at: index)
        return updatedArray
    }
    
    mutating func popFirst() -> Element? {
        guard !self.isEmpty else { return nil }
        
        return self.removeFirst()
    }
    
    func inserting(_ other: Element?, at index: Int) -> [Element] {
        guard let other: Element = other else { return self }
        
        var updatedArray: [Element] = self
        updatedArray.insert(other, at: index)
        return updatedArray
    }
    
    func inserting(contentsOf other: [Element]?, at index: Int) -> [Element] {
        guard let other: [Element] = other else { return self }
        
        var updatedArray: [Element] = self
        updatedArray.insert(contentsOf: other, at: 0)
        return updatedArray
    }
    
    func setting(_ index: Int, _ element: Element) -> [Element] {
        var updatedArray: [Element] = self
        updatedArray[index] = element
        return updatedArray
    }
    
    func grouped<Key: Hashable>(by keyForValue: (Element) throws -> Key) -> [Key: [Element]] {
        return ((try? Dictionary(grouping: self, by: keyForValue)) ?? [:])
    }
    
    func chunked(by chunkSize: Int) -> [[Element]] {
        return stride(from: 0, to: self.count, by: chunkSize).map {
            Array(self[$0..<Swift.min($0 + chunkSize, self.count)])
        }
    }
    
    func nullIfEmpty() -> [Element]? {
        guard !isEmpty else { return nil }
        
        return self
    }
}

public extension Array where Element: Hashable {
    func asSet() -> Set<Element> {
        return Set(self)
    }
}

public extension Array where Element == String {
    func reversed(if flag: Bool) -> [Element] {
        guard flag else { return self }
        
        return self.reversed()
    }
}
