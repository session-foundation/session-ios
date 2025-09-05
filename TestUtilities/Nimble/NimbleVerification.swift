// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
internal import Nimble

public struct NimbleVerification {
    public let matchingCalls: [RecordedCall]?
    public let allCallsForFunction: [RecordedCall]?
    
    public func wasCalled(exactly times: Int, fileID: String = #fileID, file: String = #filePath, line: UInt = #line) {
        expect(fileID: fileID, file: file, line: line, self).to(beCalled(exactly: times))
    }
    
    public func wasCalled(atLeast times: Int = 1, fileID: String = #fileID, file: String = #filePath, line: UInt = #line) {
        let actualCount: Int = (matchingCalls?.count ?? 0)
        let description: String = "Expected call to happen at least \(times) time(s), but was called \(actualCount) times(s)."

        expect(fileID: fileID, file: file, line: line, actualCount)
            .to(beGreaterThanOrEqualTo(times), description: description)
    }
    
    public func wasNotCalled(fileID: String = #fileID, file: String = #filePath, line: UInt = #line) {
        expect(fileID: fileID, file: file, line: line, self).to(beCalled(exactly: 0))
    }
}

public extension Mockable {
    func verify<R>(_ callBlock: @escaping (MockedType) async throws -> R) async -> NimbleVerification {
        let matching: [RecordedCall] = (await handler.recordedCalls(for: callBlock) ?? [])
        let all: [RecordedCall] = (await handler.allRecordedCalls(for: callBlock) ?? [])
        
        return NimbleVerification(
            matchingCalls: matching,
            allCallsForFunction: all
        )
    }
}

internal func beCalled(exactly times: Int) -> Matcher<NimbleVerification> {
    return Matcher { actualExpression in
        let message: ExpectationMessage = ExpectationMessage.expectedTo("be called exactly \(times) time(s)")
        
        guard let verification = try actualExpression.evaluate() else {
            return MatcherResult(status: .fail, message: message.appendedBeNilHint())
        }
        
        let actualCount: Int = (verification.matchingCalls?.count ?? 0)
        
        if actualCount == times {
            return MatcherResult(status: .matches, message: message)
        }
        
        var details: String = ""
        
        if let allCalls: [RecordedCall] = verification.allCallsForFunction, !allCalls.isEmpty {
            let callDescriptions: String = allCalls
                .map { call in
                    let args: String = call.args.map { summary(for: $0) }.joined(separator: ", ")
                    
                    return "- \(call.name) [\(args)]"
                }
                .joined(separator: "\n")
            
            details += "\n\nAll calls to this function with different arguments:\n\(callDescriptions)"
        } else {
            details += "\n\nNo other calls were made to this function."
        }
        
        return MatcherResult(
            status: .fail,
            message: message
                .appended(message: ", got \(actualCount) matching call(s).")
                .appended(details: details)
        )
    }
}
