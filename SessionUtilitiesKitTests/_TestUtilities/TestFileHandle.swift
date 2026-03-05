// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

final class TestFileHandle: FileHandleType {
    public var data: Data
    private var seekIndex: Data.Index
    
    public init(data: Data) {
        self.data = data
        self.seekIndex = data.startIndex
    }
    
    // MARK: - FileHandleType
    
    func readToEnd() throws -> Data? {
        let result: Data = data[seekIndex..<data.endIndex]
        seekIndex = data.endIndex
        return result
    }
    
    func read(upToCount count: Int) throws -> Data? {
        let oldSeekIndex: Data.Index = seekIndex
        seekIndex = min(seekIndex.advanced(by: count), data.endIndex)
        
        return Data(data[oldSeekIndex..<seekIndex])
    }
    
    func offset() throws -> UInt64 {
        return UInt64(data.startIndex.distance(to: seekIndex))
    }
    
    func seekToEnd() throws -> UInt64 {
        seekIndex = data.endIndex
        return UInt64(data.startIndex.distance(to: seekIndex))
    }

    func write<T>(contentsOf newData: T) throws where T : DataProtocol {
        let writeData: Data = Data(newData)
        let end: Data.Index = min(seekIndex.advanced(by: writeData.count), data.endIndex)
        data.replaceSubrange(seekIndex..<end, with: writeData)
        
        /// If write extends beyond current end, append the remainder
        if end == data.endIndex {
            let appended: Data = writeData[writeData.index(writeData.startIndex, offsetBy: data.endIndex - seekIndex)...]
            data.append(contentsOf: appended)
        }
        
        seekIndex = seekIndex.advanced(by: writeData.count)
    }
    
    func close() throws {}
}
