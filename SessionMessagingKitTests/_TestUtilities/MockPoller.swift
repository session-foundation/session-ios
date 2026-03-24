// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionNetworkingKit
import SessionUtilitiesKit
import TestUtilities

@testable import SessionMessagingKit

actor MockPoller<T>: PollerType, Mockable {
    nonisolated let handler: MockHandler<MockPoller>
    
    init(handler: MockHandler<MockPoller>) {
        self.handler = handler
    }
    
    init(handlerForBuilder: any MockFunctionHandler) {
        self.handler = MockHandler(forwardingHandler: handlerForBuilder)
    }
    
    typealias PollResponse = T
    
    var dependencies: Dependencies { handler.erasedDependencies as! Dependencies }
    var dependenciesKey: Dependencies.Key? { handler.erasedDependenciesKey as? Dependencies.Key }
    var pollerName: String { handler.mock() }
    var destination: PollerDestination { handler.mock() }
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
    
    init(
        pollerName: String,
        destination: PollerDestination,
        swarmDrainStrategy: SwarmDrainer.Strategy,
        namespaces: [Network.StorageServer.Namespace],
        failureCount: Int,
        numConsecutiveEmptyPolls: Int,
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
                destination,
                swarmDrainStrategy,
                namespaces,
                failureCount,
                numConsecutiveEmptyPolls,
                shouldStoreMessages,
                logStartAndStopCalls,
                customAuthMethod,
                key
            ]
        )
    }
    
    func startIfNeeded(forceStartInBackground: Bool) async {
        handler.mockNoReturn(args: [forceStartInBackground])
    }
    func stop() { handler.mockNoReturn() }
    
    func pollerDidStart() { handler.mockNoReturn() }
    func pollerReceivedResponse(_ response: PollResponse) async { handler.mockNoReturn(args: [response]) }
    func pollerDidStop() { handler.mockNoReturn() }
    func poll(forceSynchronousProcessing: Bool) async throws -> PollResult<T> {
        return try handler.mockThrowing(args: [forceSynchronousProcessing])
    }
    func pollFromBackground() async throws -> PollResult<PollResponse> {
        return try handler.mockThrowing()
    }
    func nextPollDelay() async -> TimeInterval { return handler.mock() }
    func handlePollError(_ error: Error) async { handler.mockNoReturn(args: [error]) }
}
