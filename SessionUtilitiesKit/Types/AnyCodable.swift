// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public struct AnyCodable: Codable {
    public let value: Any
    
    public init(_ value: Any) {
        self.value = value
    }
    
    public init(from decoder: Decoder) throws {
        let container: SingleValueDecodingContainer = try decoder.singleValueContainer()
        
        if let bool = try? container.decode(Bool.self) {
            value = bool
        }
        else if let int = try? container.decode(Int.self) {
            value = int
        }
        else if let double = try? container.decode(Double.self) {
            value = double
        }
        else if let string = try? container.decode(String.self) {
            value = string
        }
        else if let array = try? container.decode([AnyCodable].self) {
            value = array.map(\.value)
        }
        else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues(\.value)
        }
        else if container.decodeNil() {
            value = NSNull()
        }
        else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON type"
            )
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container: SingleValueEncodingContainer = encoder.singleValueContainer()
        
        switch value {
            case let bool as Bool: try container.encode(bool)
            case let int as Int: try container.encode(int)
            case let double as Double: try container.encode(double)
            case let string as String: try container.encode(string)
            case let array as [Any]: try container.encode(array.map { AnyCodable($0) })
            case let dict as [String: Any]: try container.encode(dict.mapValues { AnyCodable($0) })
            case is NSNull: try container.encodeNil()
            default:
                throw EncodingError.invalidValue(
                    value,
                    EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "Unsupported type")
                )
        }
    }
}
