// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
internal import Nimble

public struct NimbleVerification<M: Mockable, R> {
    fileprivate struct VerificationData {
        fileprivate let mock: M
        fileprivate let callBlock: (M.MockedType) async throws -> R
    }
    
    fileprivate let data: VerificationData
    
    public func wasCalled(
        exactly times: Int,
        timeout: DispatchTimeInterval = .seconds(0),
        fileID: String = #fileID,
        file: String = #filePath,
        line: UInt = #line
    ) async {
        if timeout == .seconds(0) {
            await expect(fileID: fileID, file: file, line: line, self.data).to(beCalled(exactly: times))
        }
        else {
            await expect(fileID: fileID, file: file, line: line, self.data)
                .toEventually(beCalled(exactly: times), timeout: timeout.nimbleInterval)
        }
    }
    
    public func wasCalled(
        atLeast times: Int = 1,
        timeout: DispatchTimeInterval = .seconds(0),
        fileID: String = #fileID,
        file: String = #filePath,
        line: UInt = #line
    ) async {
        if timeout == .seconds(0) {
            await expect(fileID: fileID, file: file, line: line, self.data).to(beCalled(atLeast: times))
        }
        else {
            await expect(fileID: fileID, file: file, line: line, self.data)
                .toEventually(beCalled(atLeast: times), timeout: timeout.nimbleInterval)
        }
    }
    
    public func wasNotCalled(
        timeout: DispatchTimeInterval = .seconds(0),
        fileID: String = #fileID,
        file: String = #filePath,
        line: UInt = #line
    ) async {
        if timeout == .seconds(0) {
            await expect(fileID: fileID, file: file, line: line, self.data).to(beCalled(exactly: 0))
        }
        else {
            await expect(fileID: fileID, file: file, line: line, self.data)
                .toEventually(beCalled(exactly: 0), timeout: timeout.nimbleInterval)
        }
    }
}

public extension Mockable {
    func verify<R>(_ callBlock: @escaping (MockedType) async throws -> R) async -> NimbleVerification<Self, R> {
        return NimbleVerification(
            data: NimbleVerification.VerificationData(mock: self, callBlock: callBlock)
        )
    }
}

private func beCalled<M, R>(
    exactly exactTimes: Int? = nil,
    atLeast atLeastTimes: Int? = nil
) -> AsyncMatcher<NimbleVerification<M, R>.VerificationData> {
    return AsyncMatcher { actualExpression in
        let message: ExpectationMessage = (atLeastTimes != nil ?
            ExpectationMessage.expectedTo("be called at least \(atLeastTimes ?? 1) time(s)") :
            ExpectationMessage.expectedTo("be called exactly \(exactTimes ?? 1) time(s)")
        )
        
        guard let info = try await actualExpression.evaluate() else {
            return MatcherResult(status: .fail, message: message.appendedBeNilHint())
        }
        
        let matchingCalls: [RecordedCall] = (await info.mock.handler.recordedCalls(for: info.callBlock) ?? [])
        
        switch (exactTimes, atLeastTimes) {
            case (.some(let times), _):
                if matchingCalls.count == times {
                    return MatcherResult(status: .matches, message: message)
                }
                
            case (_, .some(let times)):
                if matchingCalls.count >= times {
                    return MatcherResult(status: .matches, message: message)
                }
                
            case (.none, .none):
                if matchingCalls.count >= 1 {
                    return MatcherResult(status: .matches, message: message)
                }
        }
        
        var details: String = ""
        let maybeAllCalls: [RecordedCall]? = await info.mock.handler.allRecordedCalls(for: info.callBlock)
        
        if let allCalls: [RecordedCall] = maybeAllCalls, !allCalls.isEmpty {
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
                .appended(message: ", got \(matchingCalls.count) matching call(s).")
                .appended(details: details)
        )
    }
}

private extension DispatchTimeInterval {
    var nimbleInterval: NimbleTimeInterval {
        switch self {
            case .seconds(let value): return .seconds(value)
            case .milliseconds(let value): return .milliseconds(value)
            case .microseconds(let value): return .microseconds(value)
            case .nanoseconds(let value): return .nanoseconds(value)
            case .never: return .seconds(0)
            @unknown default: return .seconds(0)
        }
    }
}
