// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Nimble
import SessionUtilitiesKit

public enum CallAmount {
    case atLeast(times: Int)
    case exactly(times: Int)
    case noMoreThan(times: Int)
}

public enum ParameterMatchType {
    case none
    case all
    case atLeast(Int)
}

fileprivate extension String.StringInterpolation {
    mutating func appendInterpolation(times: Int) {
        appendInterpolation("\(times) time\(times == 1 ? "" : "s")")
    }
    
    mutating func appendInterpolation(parameters: Int) {
        appendInterpolation("\(parameters) parameter\(parameters == 1 ? "" : "s")")
    }
}

/// Validates whether the function called in `functionBlock` has been called according to the parameter constraints
///
/// - Parameters:
///  - amount: An enum constraining the number of times the function can be called (Default is `.atLeast(times: 1)`
///
///  - matchingParameters: A boolean indicating whether the parameters for the function call need to match exactly
///
///  - exclusive: A boolean indicating whether no other functions should be called
///
///  - functionBlock: A closure in which the function to be validated should be called
public func call<M, T, R>(
    _ amount: CallAmount = .atLeast(times: 1),
    matchingParameters: ParameterMatchType = .none,
    exclusive: Bool = false,
    functionBlock: @escaping (inout T) async throws -> R
) -> Matcher<M> where M: Mock<T> {
    return Matcher.define { actualExpression in
        /// First generate the call info
        let callInfo: CallInfo = generateCallInfo(actualExpression, functionBlock)
        let expectedDescription: String = {
            let timesDescription: String? = {
                switch amount {
                    case .atLeast(let times): return (times <= 1 ? nil : "at least \(times: times)")
                    case .exactly(let times): return "exactly \(times: times)"
                    case .noMoreThan(let times): return (times <= 0 ? nil : "no more than \(times: times))")
                }
            }()
            let matchingParametersDescription: String? = {
                let paramInfo: String = (callInfo.targetFunctionParameters.map { ": \($0)" } ?? "")
                
                switch matchingParameters {
                    case .none: return nil
                    case .all: return "matching the parameters\(paramInfo)"
                    case .atLeast(let count): return "matching at least \(parameters: count)"
                }
            }()
            
            return [
                "call '\(callInfo.functionName)'\(exclusive ? " exclusively" : "")",
                timesDescription,
                matchingParametersDescription
            ]
            .compactMap { $0 }
            .joined(separator: " ")
        }()
        
        /// If an error was thrown when generating call info then fail (mock value likely invalid)
        guard callInfo.caughtError == nil else {
            return MatcherResult(
                bool: false,
                message: .expectedCustomValueTo(
                    expectedDescription,
                    actual: "an error (invalid mock param, not called or no mocked return value)"
                )
            )
        }
        
        /// If there is no function within the 'callInfo' then we can't provide more useful info
        guard let targetFunction: MockFunction = callInfo.targetFunction else {
            return MatcherResult(
                bool: false,
                message: .expectedCustomValueTo(
                    expectedDescription,
                    actual: "no call details"
                )
            )
        }
        
        /// If the mock wasn't called at all then no other data will be useful
        guard !callInfo.allFunctionsCalled.isEmpty else {
            return MatcherResult(
                bool: false,
                message: .expectedCustomValueTo(
                    expectedDescription,
                    actual: "no calls"
                )
            )
        }
        
        /// If we require the call to be exclusive (ie. the only function called on the mock) then make sure there were no
        /// other functions called
        guard
            !exclusive ||
            callInfo.allFunctionsCalled.count == 0 || (
                callInfo.allFunctionsCalled.count == 1 &&
                callInfo.allFunctionsCalled[0].name == targetFunction.name
            )
        else {
            let otherFunctionsCalled: [String] = callInfo.allFunctionsCalled
                .map { "\($0.name) (params: \($0.paramCount))" }
                .filter { $0 != "\(callInfo.functionName) (params: \(callInfo.parameterCount))" }
            
            return MatcherResult(
                bool: false,
                message: .expectedCustomValueTo(
                    expectedDescription,
                    actual: "calls to other functions: [\(otherFunctionsCalled.joined(separator: ", "))]"
                )
            )
        }
        
        /// Check how accurate the calls made actually were
        let validTargetParameterCombinations: Set<String> = targetFunction.allParameterSummaryCombinations
            .filter { combination -> Bool in
                switch matchingParameters {
                    case .none: return true
                    case .all: return (combination.count == targetFunction.parameterCount)
                    case .atLeast(let count): return (combination.count >= count)
                }
            }
            .map { $0.summary }
            .asSet()
        let allValidCallDetails: [CallDetails] = callInfo.allCallDetails
            .compactMap { details -> CallDetails? in
                let validCombinations: [ParameterCombination] = details.allParameterSummaryCombinations
                    .filter { combination in
                        switch matchingParameters {
                            case .none: return true
                            case .all:
                                return (
                                    combination.count == targetFunction.parameterCount &&
                                    combination.summary == targetFunction.parameterSummary
                                )
                                
                            case .atLeast(let count):
                                return (
                                    combination.count >= count &&
                                    validTargetParameterCombinations.contains(combination.summary)
                                )
                        }
                    }
                
                guard !validCombinations.isEmpty else { return nil }
                
                return CallDetails(
                    parameterSummary: details.parameterSummary,
                    allParameterSummaryCombinations: validCombinations
                )
            }
        let metCallCountRequirement: Bool = {
            switch amount {
                case .atLeast(let times): return (allValidCallDetails.count >= times)
                case .exactly(let times): return (allValidCallDetails.count == times)
                case .noMoreThan(let times): return (allValidCallDetails.count <= times)
            }
        }()
        let allCallsMetParamRequirements: Bool = (allValidCallDetails.count == callInfo.allCallDetails.count)
        let totalUniqueParamCount: Int = callInfo.allCallDetails
            .map { $0.parameterSummary }
            .asSet()
            .count
        
        switch (exclusive, metCallCountRequirement, allCallsMetParamRequirements, totalUniqueParamCount) {
            /// No calls with the matching parameter requirements but only one parameter combination so include the param info
            case (_, false, false, 1):
                return MatcherResult(
                    bool: false,
                    message: .expectedCustomValueTo(
                        expectedDescription,
                        actual: "called \(times: callInfo.allCallDetails.count) with different parameters: \(callInfo.allCallDetails[0].parameterSummary)"
                    )
                )
                
            /// The calls were made with the correct parameters, but didn't call enough times
            case (_, false, true, _):
                return MatcherResult(
                    bool: false,
                    message: .expectedCustomValueTo(
                        expectedDescription,
                        actual: "called \(times: callInfo.allCallDetails.count)"
                    )
                )
                
            /// There were multiple parameter combinations
            ///
            /// **Note:** A getter/setter combo will have function calls split between no params and the set value, if the
            /// setter didn't match then we still want to show the incorrect parameters
            case (true, true, false, _), (_, false, false, _):
                let distinctSetterCombinations: Set<CallDetails> = callInfo.allCallDetails
                    .filter { $0.parameterSummary != "[]" }
                    .asSet()
                let maxParamMatch: Int = allValidCallDetails
                    .flatMap { $0.allParameterSummaryCombinations.map { $0.count } }
                    .max()
                    .defaulting(to: 0)
                
                return MatcherResult(
                    bool: false,
                    message: .expectedCustomValueTo(
                        expectedDescription,
                        actual: {
                            guard distinctSetterCombinations.count != 1 else {
                                return "called with: \(Array(distinctSetterCombinations)[0].parameterSummary)"
                            }
                            
                            return (
                                "called \(times: allValidCallDetails.count) with matching parameters " +
                                "(\(times: callInfo.allCallDetails.count) total" + (
                                    !metCallCountRequirement ? ")" :
                                    ", matching at most \(parameters: maxParamMatch))"
                                )
                            )
                        }()
                    )
                )

            default:
                return MatcherResult(
                    bool: true,
                    message: .expectedCustomValueTo(
                        expectedDescription,
                        actual: "call to '\(callInfo.functionName)'"
                    )
                )
        }
    }
}

// MARK: - Shared Code

fileprivate struct CallInfo {
    let didError: Bool
    let caughtError: Error?
    let targetFunction: MockFunction?
    let allFunctionsCalled: [FunctionConsumer_Old.Key]
    let allCallDetails: [CallDetails]
    
    var functionName: String { "\((targetFunction?.name).map { "\($0)" } ?? "a function")" }
    var parameterCount: Int { (targetFunction?.parameterCount ?? 0) }
    var targetFunctionParameters: String? { targetFunction?.parameterSummary }
    
    static var error: CallInfo {
        CallInfo(
            didError: true,
            caughtError: nil,
            targetFunction: nil,
            allFunctionsCalled: [],
            allCallDetails: []
        )
    }
    
    init(
        didError: Bool = false,
        caughtError: Error?,
        targetFunction: MockFunction?,
        allFunctionsCalled: [FunctionConsumer_Old.Key],
        allCallDetails: [CallDetails]
    ) {
        self.didError = didError
        self.caughtError = caughtError
        self.targetFunction = targetFunction
        self.allFunctionsCalled = allFunctionsCalled
        self.allCallDetails = allCallDetails
    }
}

fileprivate func generateCallInfo<M, T, R>(
    _ actualExpression: Nimble.Expression<M>,
    _ functionBlock: @escaping (inout T) async throws -> R
) -> CallInfo where M: Mock<T> {
    var maybeTargetFunction: MockFunction?
    var allFunctionsCalled: [FunctionConsumer_Old.Key] = []
    var allCallDetails: [CallDetails] = []
    var caughtError: Error? = nil
    
    // Just hope for the best and if there is a force-cast there's not much we can do
    do {
        guard let validInstance: M = try actualExpression.evaluate() else {
            throw TestError.unableToEvaluateExpression
        }
        
        allFunctionsCalled = Array(validInstance.functionConsumer.calls.keys)
        
        // Only check for the specific function calls if there was at least a single
        // call (if there weren't any this will likely throw errors when attempting
        // to build)
        if !allFunctionsCalled.isEmpty {
            validInstance.functionConsumer.trackCalls = false
            maybeTargetFunction = try MockFunctionBuilder_Old.mockFunctionWith(validInstance, functionBlock)
            
            let key: FunctionConsumer_Old.Key = FunctionConsumer_Old.Key(
                name: (maybeTargetFunction?.name ?? ""),
                generics: (maybeTargetFunction?.generics ?? []),
                paramCount: (maybeTargetFunction?.parameterCount ?? 0)
            )
            allCallDetails = validInstance.functionConsumer.calls[key]
                .defaulting(to: [])
            validInstance.functionConsumer.trackCalls = true
        }
        else {
            allCallDetails = []
        }
    }
    catch { caughtError = error }
    
    return CallInfo(
        caughtError: caughtError,
        targetFunction: maybeTargetFunction,
        allFunctionsCalled: allFunctionsCalled,
        allCallDetails: allCallDetails
    )
}

public extension SyncExpectation {
    func retrieveValue() async -> Value? {
        return try? expression.evaluate()
    }
}

public extension AsyncExpectation {
    func retrieveValue() async -> Value? {
        return try? await expression.evaluate()
    }
}
