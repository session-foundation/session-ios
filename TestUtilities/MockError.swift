// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

public enum MockError: Error, CustomStringConvertible {
    case any
    case mock
    case noStubFound(function: String, args: [Any?])
    case noMatchingStubFound(function: String, expectedArgs: [Any?], mockedArgs: [[Any?]])
    case stubbedValueIsWrongType(function: String, expected: Any.Type, actual: Any.Type?)
    case invalidWhenBlock(message: String)
    
    public var shouldLogFailure: Bool {
        switch self {
            case .noStubFound, .noMatchingStubFound: return true
            default: return false
        }
    }
    
    public var description: String {
        switch self {
            case .any: return "AnyError"
            case .mock: return "MockError: This error should never be thrown."
            case .noStubFound(let function, let args):
                let argsDescription: String = args.map { summary(for: $0) }.joined(separator: ", ")
                
                return "MockError: No stub found for '\(function)(\(argsDescription))'. Use .when { ... } to provide a return value or action."
                
            case .noMatchingStubFound(let function, let expectedArgs, let mockedArgs):
                guard !expectedArgs.isEmpty && !mockedArgs.isEmpty else {
                    return MockError.noStubFound(function: function, args: []).description
                }
                
                var errorDescription: String = "MockError: A stub for \(function) was found, but the parameters didn't match."
                
                errorDescription += "\n\nCalled with parameters:"
                let args: String = expectedArgs.map { summary(for: $0) }.joined(separator: ", ")
                errorDescription += "\n- [\(args)]"
                
                let callDescriptions: String = mockedArgs
                    .map { args in
                        let argString: String = args.map { summary(for: $0) }.joined(separator: ", ")
                        
                        return "- [\(argString)]"
                    }
                    .joined(separator: "\n")
                errorDescription += "\n\nAll stubs:\n\(callDescriptions)"
                
                return errorDescription
            
            case .stubbedValueIsWrongType(let function, let expected, let actual):
                return "MockError: A stub for \(function) was found, but its return value is the wrong type. Expected '\(expected)', but found '\(actual.map { "\($0)" } ?? "nil")'."
            
            case .invalidWhenBlock(let message):
                return "MockError: Invalid `when` block. \(message)"
        }
    }
}

