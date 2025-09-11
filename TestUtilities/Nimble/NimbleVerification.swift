// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
internal import Nimble

public struct NimbleVerification<M: Mockable, R> {
    fileprivate struct VerificationData {
        fileprivate let mock: M
        fileprivate let callBlock: (inout M.MockedType) async throws -> R
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
                .toEventually(
                    beCalled(exactly: times),
                    timeout: timeout.nimbleInterval,
                    description: "Timed out waiting for call count to be \(times)."
                )
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
                .toEventually(
                    beCalled(atLeast: times),
                    timeout: timeout.nimbleInterval,
                    description: "Timed out waiting for call count to be at least \(times)."
                )
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
                .toEventually(
                    beCalled(exactly: 0),
                    timeout: timeout.nimbleInterval,
                    description: "Timed out waiting for call count to be 0."
                )
        }
    }
}

public extension Mockable {
    func verify<R>(_ callBlock: @escaping (inout MockedType) async throws -> R) async -> NimbleVerification<Self, R> {
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
        let message: ExpectationMessage
        
        switch (exactTimes, atLeastTimes) {
            case (_, 1), (.none, .none): message = ExpectationMessage.expectedTo("be called at least 1 time")
            case (_, .some(let atLeastTimes)):
                message = ExpectationMessage.expectedTo("be called at least \(atLeastTimes) time(s)")
            
            case (0, _): message = ExpectationMessage.expectedTo("not be called")
            case (1, _): message = ExpectationMessage.expectedTo("be called exactly 1 time")
            case (.some(let exactTimes), _):
                message = ExpectationMessage.expectedTo("be called exactly \(exactTimes) time(s)")
        }
        
        guard let info = try await actualExpression.evaluate() else {
            return MatcherResult(status: .fail, message: message.appendedBeNilHint())
        }
        
        let callInfo: MockHandler.CallInfo? = await info.mock.handler.recordedCallInfo(for: info.callBlock)
        
        switch (exactTimes, atLeastTimes) {
            case (.some(let times), _):
                if callInfo?.matching.count == times {
                    return MatcherResult(status: .matches, message: message)
                }
                
            case (_, .some(let times)):
                if (callInfo?.matching.count ?? 0) >= times {
                    return MatcherResult(status: .matches, message: message)
                }
                
            case (.none, .none):
                if (callInfo?.matching.count ?? 0) >= 1 {
                    return MatcherResult(status: .matches, message: message)
                }
        }
        
        var details: String = ""
        
        if (exactTimes ?? 0) > 0 || (atLeastTimes ?? 0) > 0 {
            details += "\nExpected to call \((callInfo?.expected.name).map { "'\($0)'" } ?? "function") with parameters:"
            
            if let expectedCall: RecordedCall = callInfo?.expected {
                let args: String = expectedCall.arguments.map { summary(for: $0) }.joined(separator: ", ")
                details += "\n- [\(args)]"
            }
            else {
                details += "\n- Unable to determine the expected parameters"
            }
            
            details += "\n"
        }
        
        if let allCalls: [RecordedCall] = callInfo?.all, !allCalls.isEmpty {
            let callDescriptions: String = allCalls
                .map { call in
                    let args: String = call.arguments.map { summary(for: $0) }.joined(separator: ", ")
                    
                    return "- [\(args)]"
                }
                .joined(separator: "\n")
            
            details += "\nAll calls to this function with different arguments:\n\(callDescriptions)"
        } else {
            details += "\nNo other calls were made to this function."
        }
        
        let gotMessage: String = ((exactTimes ?? 0) > 0 || (atLeastTimes ?? 0) > 0 ?
            ", got \(callInfo?.matching.count ?? 0) matching call(s)." :
            ", got called \(callInfo?.matching.count ?? 0) time(s)."
        )
        
        return MatcherResult(
            status: .fail,
            message: message
                .appended(message: gotMessage)
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
