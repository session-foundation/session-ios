// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

public enum MockError: Error, CustomStringConvertible {
    case any
    case mock
    case noStubFound(function: String, args: [Any?])
    case stubbedValueIsWrongType(expected: Any.Type, actual: Any.Type?)
    case cannotCreateDummyValue(type: Any.Type, function: String)
    case invalidWhenBlock(message: String)
    
    public var description: String {
        switch self {
            case .any: return "AnyError"
            case .mock: return "MockError: This error should never be thrown."
            case .noStubFound(let function, let args):
                let argsDescription: String = args.map { summary(for: $0) }.joined(separator: ", ")
                
                return "MockError: No stub found for '\(function)(\(argsDescription))'. Use .when { ... } to provide a return value or action."
            
            case .stubbedValueIsWrongType(let expected, let actual):
                return "MockError: A stub for this function was found, but its return value is the wrong type. Expected '\(expected)', but found '\(actual.map { "\($0)" } ?? "nil")'."
                
            case .cannotCreateDummyValue(let type, let function):
                return "MockError: The function '\(function)' being stubbed returns a non-optional value of type '\(type)', which does not conform to the 'Mocked' protocol. Please add conformance to provide a default value."
            
            case .invalidWhenBlock(let message):
                return "MockError: Invalid `when` block. \(message)"

        }
    }
}

