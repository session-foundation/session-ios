// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public protocol BencodableType {
    associatedtype ValueType: BencodableType
    
    static var isCollection: Bool { get }
    static var isDictionary: Bool { get }
}

public struct BencodeResponse<T: Codable> {
    public let info: T
    public let data: Data?
}

extension BencodeResponse: Equatable where T: Equatable {}

public enum Bencode {
    private enum Element: Character {
        case number0 = "0"
        case number1 = "1"
        case number2 = "2"
        case number3 = "3"
        case number4 = "4"
        case number5 = "5"
        case number6 = "6"
        case number7 = "7"
        case number8 = "8"
        case number9 = "9"
        case intIndicator = "i"
        case listIndicator = "l"
        case dictIndicator = "d"
        case endIndicator = "e"
        case separator = ":"
        
        init?(_ byte: UInt8?) {
            guard
                let byte: UInt8 = byte,
                let byteString: String = String(data: Data([byte]), encoding: .utf8),
                let character: Character = byteString.first,
                let result: Element = Element(rawValue: character)
            else { return nil }
            
            self = result
        }
    }
    
    private struct BencodeString {
        let value: String?
        let rawValue: Data
    }
    
    // MARK: - Functions
    
    public static func decodeResponse<T>(
        from data: Data,
        using dependencies: Dependencies = Dependencies()
    ) throws -> BencodeResponse<T> where T: Decodable {
        guard
            let result: [Data] = try? decode([Data].self, from: data),
            let responseData: Data = result.first
        else { throw HTTPError.parsingFailed }
        
        return BencodeResponse(
            info: try responseData.decoded(as: T.self, using: dependencies),
            data: (result.count > 1 ? result.last : nil)
        )
    }
    
    public static func decode<T: BencodableType>(_ type: T.Type, from data: Data) throws -> T {
        guard
            let decodedData: (value: Any, remainingData: Data) = decodeData(data),
            decodedData.remainingData.isEmpty == true  // Ensure there is no left over data
        else { throw HTTPError.parsingFailed }
        
        return try recursiveCast(type, from: decodedData.value)
    }
    
    // MARK: - Logic
    
    private static func decodeData(_ data: Data) -> (value: Any, remainingData: Data)? {
        switch Element(data.first) {
            case .number0, .number1, .number2, .number3, .number4,
                .number5, .number6, .number7, .number8, .number9:
                return decodeString(data)
                
            case .intIndicator: return decodeInt(data)
            case .listIndicator: return decodeList(data)
            case .dictIndicator: return decodeDict(data)
            default: return nil
        }
    }
    
    /// Decode a string element from iterator assumed to have structure `{length}:{data}`
    private static func decodeString(_ data: Data) -> (value: BencodeString, remainingData: Data)? {
        var mutableData: Data = data
        var lengthData: [UInt8] = []
        
        // Remove bytes until we hit the separator
        while let next: UInt8 = mutableData.popFirst(), Element(next) != .separator {
            lengthData.append(next)
        }
        
        // Need to reset the index of the data (it maintains the index after popping/slicing)
        // See https://forums.swift.org/t/data-subscript/57195 for more info
        mutableData = Data(mutableData)
        
        guard
            let lengthString: String = String(data: Data(lengthData), encoding: .ascii),
            let length: Int = Int(lengthString, radix: 10),
            mutableData.count >= length
        else { return nil }
        
        // Need to reset the index of the data (it maintains the index after popping/slicing)
        // See https://forums.swift.org/t/data-subscript/57195 for more info
        return (
            BencodeString(
                value: String(data: mutableData[0..<length], encoding: .ascii),
                rawValue: mutableData[0..<length]
            ),
            Data(mutableData.dropFirst(length))
        )
    }
    
    /// Decode an int element from iterator assumed to have structure `i{int}e`
    private static func decodeInt(_ data: Data) -> (value: Int, remainingData: Data)? {
        var mutableData: Data = data
        var intData: [UInt8] = []
        _ = mutableData.popFirst() // drop `i`
        
        // Pop until after `e`
        while let next: UInt8 = mutableData.popFirst(), Element(next) != .endIndicator {
            intData.append(next)
        }
        
        guard
            let intString: String = String(data: Data(intData), encoding: .ascii),
            let result: Int = Int(intString, radix: 10)
        else { return nil }
        
        // Need to reset the index of the data (it maintains the index after popping/slicing)
        // See https://forums.swift.org/t/data-subscript/57195 for more info
        return (result, Data(mutableData))
    }
    
    /// Decode a list element from iterator assumed to have structure `l{data}e`
    private static func decodeList(_ data: Data) -> ([Any], Data)? {
        var mutableData: Data = data
        var listElements: [Any] = []
        _ = mutableData.popFirst() // drop `l`
        
        while !mutableData.isEmpty, let next: UInt8 = mutableData.first, Element(next) != .endIndicator {
            guard let result = decodeData(mutableData) else { break }
                
            listElements.append(result.value)
            mutableData = result.remainingData
        }
        
        _ = mutableData.popFirst() // drop `e`
        
        // Need to reset the index of the data (it maintains the index after popping/slicing)
        // See https://forums.swift.org/t/data-subscript/57195 for more info
        return (listElements, Data(mutableData))
    }
    
    /// Decode a dict element from iterator assumed to have structure `d{data}e`
    private static func decodeDict(_ data: Data) -> ([String: Any], Data)? {
        var mutableData: Data = data
        var dictElements: [String: Any] = [:]
        _ = mutableData.popFirst() // drop `d`
        
        while !mutableData.isEmpty, let next: UInt8 = mutableData.first, Element(next) != .endIndicator {
            guard
                let keyResult = decodeString(mutableData),
                let key: String = keyResult.value.value,
                let valueResult = decodeData(keyResult.remainingData)
            else { return nil }
            
            dictElements[key] = valueResult.value
            mutableData = valueResult.remainingData
        }
        
        _ = mutableData.popFirst() // drop `e`
        
        // Need to reset the index of the data (it maintains the index after popping/slicing)
        // See https://forums.swift.org/t/data-subscript/57195 for more info
        return (dictElements, Data(mutableData))
    }
    
    // MARK: - Internal Functions
    
    private static func recursiveCast<T: BencodableType>(_ type: T.Type, from value: Any) throws -> T {
        switch (type.isCollection, type.isDictionary) {
            case (_, true):
                guard let dictValue: [String: Any] = value as? [String: Any] else { throw HTTPError.parsingFailed }
                
                return try (
                    dictValue.mapValues { try recursiveCast(type.ValueType.self, from: $0) } as? T ??
                    { throw HTTPError.parsingFailed }()
                )
                
            case (true, _):
                guard let arrayValue: [Any] = value as? [Any] else { throw HTTPError.parsingFailed }
                
                return try (
                    arrayValue.map { try recursiveCast(type.ValueType.self, from: $0) } as? T ??
                    { throw HTTPError.parsingFailed }()
                )
                
            default:
                switch (value, type) {
                    case (let bencodeString as BencodeString, is String.Type):
                        return try (bencodeString.value as? T ?? { throw HTTPError.parsingFailed }())
                        
                    case (let bencodeString as BencodeString, is Optional<String>.Type):
                        return try (bencodeString.value as? T ?? { throw HTTPError.parsingFailed }())
                        
                    case (let bencodeString as BencodeString, _):
                        return try (bencodeString.rawValue as? T ?? { throw HTTPError.parsingFailed }())
                        
                    default: return try (value as? T ?? { throw HTTPError.parsingFailed }())
                }
        }
    }
}

// MARK: - BencodableType Extensions

extension Data: BencodableType {
    public typealias ValueType = Data
    
    public static var isCollection: Bool { false }
    public static var isDictionary: Bool { false }
}

extension Int: BencodableType {
    public typealias ValueType = Int
    
    public static var isCollection: Bool { false }
    public static var isDictionary: Bool { false }
}

extension String: BencodableType {
    public typealias ValueType = String
    
    public static var isCollection: Bool { false }
    public static var isDictionary: Bool { false }
}

extension Array: BencodableType where Element: BencodableType {
    public typealias ValueType = Element
    
    public static var isCollection: Bool { true }
    public static var isDictionary: Bool { false }
}

extension Dictionary: BencodableType where Key == String, Value: BencodableType {
    public typealias ValueType = Value
    
    public static var isCollection: Bool { false }
    public static var isDictionary: Bool { true }
}
