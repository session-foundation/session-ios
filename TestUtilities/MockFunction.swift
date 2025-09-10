// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

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
    
    private func isEquatableMatch<E: Equatable>(lhs: E, rhs: Any) -> Bool {
        if let rhs = rhs as? E {
            return lhs == rhs
        }
        
        return false
    }
    
    private func isAnyValue(_ value: Any) -> Bool {
        func open<T: Mocked>(value: T) -> Bool {
            if let mockedEquatable = value as? any Equatable {
                return isEquatableMatch(lhs: mockedEquatable, rhs: T.any)
            }
            
            /// Compare using the `summary` as a fallback
            return summary(for: value) == summary(for: T.any)
        }
        
        if let mockedValue = value as? any Mocked {
            return open(value: mockedValue)
        }
        
        return false
    }
    
    private func argumentMatches(stubArg: Any?, callArg: Any?) -> Bool {
        func isWildcardMatch<T: Mocked>(_ value: T) -> Bool {
            if isAnyValue(value) {
                /// The value is an `any` so check if the mocked type is a "super" wildcard (like `MockEndpoint.any` that
                /// matches any other value
                if T.skipTypeMatchForAnyComparison {
                    return true
                }
                
                /// Otherwise the types need to match
                return callArg is T
            }
            
            /// Not a wildcard
            return false
        }
        
        switch (stubArg, callArg) {
            case (.none, .none): return true    /// Too hard to compare `nil == nil` after type erasure
            case (.none, .some): return false   /// Expected `nil`, given a value
            case (.some(let lhs), .none): return isAnyValue(lhs)    /// Allow `any == nil`
            case (.some(let stub), .some(let call)):
                /// If the `stubArg` is `Mocked.any` then we want to match anything
                if let mockedStub = stub as? any Mocked, isWildcardMatch(mockedStub) {
                    return true
                }
                
                /// Check if there is an equatable match first (for performance reasons)
                if let equatableValue = stub as? any Equatable, isEquatableMatch(lhs: equatableValue, rhs: call) {
                    return true
                }
                
                /// Otherwise we need to use reflection to to a nested equality check (just in case a child element is a wildcard)
                let mirrorLhs: Mirror = Mirror(reflecting: stub)
                let mirrorRhs: Mirror = Mirror(reflecting: call)
                
                /// Since the `stub` isn't a wildcard the types need to match
                guard String(describing: mirrorLhs.subjectType) == String(describing: mirrorRhs.subjectType) else {
                    return false
                }
                
                switch mirrorLhs.displayStyle {
                    case .struct, .class, .tuple, .collection, .dictionary, .enum:
                        let childrenLhs: [Mirror.Child] = Array(mirrorLhs.children)
                        let childrenRhs: [Mirror.Child] = Array(mirrorRhs.children)
                        
                        /// If they are simple enums with no associated types then just compare the `summary` value
                        if childrenLhs.isEmpty && childrenRhs.isEmpty && mirrorLhs.displayStyle == .enum {
                            return summary(for: stub) == summary(for: call)
                        }
                        
                        /// Check enum case names are the same if applicable
                        if mirrorLhs.displayStyle == .enum {
                            let caseNameLhs: String = String(describing: stub).before(first: "(")
                            let caseNameRhs: String = String(describing: call).before(first: "(")
                            
                            if caseNameLhs != caseNameRhs {
                                return false
                            }
                        }
                        
                        /// If the number of args differ then there isn't a match
                        guard childrenLhs.count == childrenRhs.count else { return false }
                        
                        /// If any of the arguments don't match (recursively) then there is no match
                        for i in 0..<childrenLhs.count {
                            if !argumentMatches(stubArg: childrenLhs[i].value, callArg: childrenRhs[i].value) {
                                return false
                            }
                        }
                        
                        /// All arguments match
                        return true
                        
                    default:
                        /// If it was a primitive and the equatable check failed then it wasn't a match
                        if stub is any Equatable {
                            return false
                        }
                        
                        /// Otherwise we fallback to the `summary` to check equality
                        return summary(for: stub) == summary(for: call)
                }
        }
    }
}

private extension String {
    func before(first delimiter: Character) -> String {
        if let index: String.Index = firstIndex(of: delimiter) {
            return String(prefix(upTo: index))
        }
        
        return self
    }
}
