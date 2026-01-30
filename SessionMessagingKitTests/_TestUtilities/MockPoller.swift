// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionNetworkingKit
import SessionUtilitiesKit
import TestUtilities

@testable import SessionMessagingKit

class MockPoller<T>: PollerType, Mockable {
    nonisolated let handler: MockHandler<MockPoller>
    
    required init(handler: MockHandler<MockPoller>) {
        self.handler = handler
    }
    
    required init(handlerForBuilder: any MockFunctionHandler) {
        self.handler = MockHandler(forwardingHandler: handlerForBuilder)
    }
    
    typealias PollResponse = T
    
    var dependencies: Dependencies { handler.erasedDependencies as! Dependencies }
    var dependenciesKey: Dependencies.Key? { nil }
    var pollerQueue: DispatchQueue { DispatchQueue.main }
    var pollerName: String { handler.mock() }
    var pollerDestination: PollerDestination { handler.mock() }
    var logStartAndStopCalls: Bool { handler.mock() }
    nonisolated var receivedPollResponse: AsyncStream<T> { handler.mock() }
    nonisolated var successfulPollCount: AsyncStream<Int> { handler.mock() }
    
    var pollTask: Task<Void, Error>? {
        get { handler.mock() }
        set { handler.mockNoReturn(args: [newValue]) }
    }
    var pollCount: Int {
        get { handler.mock() }
        set { handler.mockNoReturn(args: [newValue]) }
    }
    var failureCount: Int {
        get { handler.mock() }
        set { handler.mockNoReturn(args: [newValue]) }
    }
    var lastPollStart: TimeInterval {
        get { handler.mock() }
        set { handler.mockNoReturn(args: [newValue]) }
    }
    var cancellable: AnyCancellable? {
        get { handler.mock() }
        set { handler.mockNoReturn(args: [newValue]) }
    }
    
    required init(
        pollerName: String,
        pollerQueue: DispatchQueue,
        pollerDestination: PollerDestination,
        swarmDrainStrategy: SwarmDrainer.Strategy,
        namespaces: [Network.SnodeAPI.Namespace],
        failureCount: Int,
        shouldStoreMessages: Bool,
        logStartAndStopCalls: Bool,
        customAuthMethod: (any AuthenticationMethod)?,
        key: Dependencies.Key?,
        using dependencies: Dependencies
    ) {
        handler = MockHandler(
            dummyProvider: { _ in MockPoller(handler: .invalid()) },
            erasedDependenciesKey: key,
            using: dependencies
        )
        handler.mockNoReturn(
            args: [
                pollerName,
                pollerQueue,
                pollerDestination,
                swarmDrainStrategy,
                namespaces,
                failureCount,
                shouldStoreMessages,
                logStartAndStopCalls,
                customAuthMethod,
                key
            ]
        )
    }
    
    func startIfNeeded(forceStartInBackground: Bool) { handler.mockNoReturn(args: [forceStartInBackground]) }
    func stop() { handler.mockNoReturn() }
    
    func pollerDidStart() { handler.mockNoReturn() }
    func poll(forceSynchronousProcessing: Bool) async throws -> PollResult<T> {
        return handler.mock(args: [forceSynchronousProcessing])
    }
    func nextPollDelay() async -> TimeInterval { return handler.mock() }
    func handlePollError(_ error: Error, _ lastError: Error?) -> PollerErrorResponse {
        handler.mock(args: [error, lastError])
    }
}
