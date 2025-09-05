// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

internal final class MockFunction {
    let name: String
    let generics: [Any.Type]
    let arguments: [Any?]
    let returnValue: Any?
    let returnError: (any Error)?
    let actions: [([Any?]) -> Void]
    
    init(
        name: String,
        generics: [Any.Type],
        arguments: [Any?],
        returnValue: Any?,
        returnError: Error?,
        actions: [([Any?]) -> Void]
    ) {
        self.name = name
        self.generics = generics
        self.arguments = arguments
        self.returnValue = returnValue
        self.returnError = returnError
        self.actions = actions
    }
    
    func matches(args: [Any?]) -> Bool {
        guard args.count == arguments.count else { return false }
        
        for (stubArg, callArg) in zip(arguments, args) {
            if !argumentMatches(stubArg: stubArg, callArg: callArg) {
                return false
            }
        }
        
        return true
    }
    
    private func argumentMatches(stubArg: Any?, callArg: Any?) -> Bool {
        func isStubArgAnAnyMatcher<T: Mocked>(value: T) -> Bool {
            return areEqual(value, T.any)
        }
        
        switch (stubArg, callArg) {
            case (.none, .none): return true    /// Too hard to compare `nil == nil` after type erasure
            case (.none, .some): return false   /// Expected `nil`, given a value
            case (.some(let stub as any Mocked), .none):
                return isStubArgAnAnyMatcher(value: stub)
            
            case (.some, .none): return false   /// Expected non-`nil` value for non-`Mocked` type, given `nil`
            case (.some(let stub), .some(let call)):
                /// If the `stubArg` is `Mocked.any` then we want to match anything
                if let mockedStub = stub as? any Mocked, isStubArgAnAnyMatcher(value: mockedStub) {
                    return type(of: stub) == type(of: call)
                }
                
                /// Otherwise we need to do some form of equality check
                return areEqual(stub, call)
        }
    }
    
    private func areEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        func open<T: Equatable>(lhs: T, rhs: Any) -> Bool {
            if let rhs = rhs as? T {
                return lhs == rhs
            }
            
            return false
        }

        if let equatableLhs = lhs as? any Equatable {
            return open(lhs: equatableLhs, rhs: rhs)
        }

        /// Compare using the `summary` as a fallback
        return summary(for: lhs) == summary(for: rhs)
    }
}
