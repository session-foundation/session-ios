// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension Array where Element: CustomStringConvertible {
    var prettifiedDescription: String {
        return "[ " + map { $0.description }.joined(separator: ", ") + " ]"
    }
}

@inlinable public func zip<Sequence1, Sequence2, Sequence3>(_ sequence1: Sequence1, _ sequence2: Sequence2, _ sequence3: Sequence3) -> Array<(Sequence1.Element, Sequence2.Element, Sequence3.Element)> where Sequence1: Sequence, Sequence2: Sequence, Sequence3: Sequence {
    return zip(zip(sequence1, sequence2), sequence3)
        .map { firstZip, third -> (Sequence1.Element, Sequence2.Element, Sequence3.Element) in (firstZip.0, firstZip.1, third) }
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
    
    func grouped<Key: Hashable>(by keyForValue: (Element) throws -> Key) -> [Key: [Element]] {
        return ((try? Dictionary(grouping: self, by: keyForValue)) ?? [:])
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
