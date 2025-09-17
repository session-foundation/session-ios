// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionNetworkingKit
import SessionUtilitiesKit
import TestUtilities

@testable import SessionMessagingKit

actor MockPoller: PollerType, Mockable {
    typealias PollResponse = Void
    
    nonisolated let handler: MockHandler<MockPoller>
    
    var dependencies: Dependencies { handler.erasedDependencies as! Dependencies }
    var dependenciesKey: Dependencies.Key? { handler.erasedDependenciesKey as? Dependencies.Key }
    var pollerName: String { handler.mock() }
    var destination: PollerDestination { handler.mock() }
    var logStartAndStopCalls: Bool { handler.mock() }
    nonisolated var receivedPollResponse: AsyncStream<PollResponse> { handler.mock() }
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
    var pollTask: Task<Void, Error>? {
        get { handler.mock() }
        set { handler.mockNoReturn(args: [newValue]) }
    }
    
    init(
        pollerName: String,
        destination: PollerDestination,
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
                destination,
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
    
    internal init(handler: MockHandler<MockPoller>) {
        self.handler = handler
    }
    
    internal init(handlerForBuilder: any MockFunctionHandler) {
        self.handler = MockHandler(forwardingHandler: handlerForBuilder)
    }
    
    func startIfNeeded(forceStartInBackground: Bool) async { handler.mockNoReturn(args: [forceStartInBackground]) }
    func stop() { handler.mockNoReturn() }
    
    func pollerDidStart() { handler.mockNoReturn() }
    func pollerReceivedResponse(_ response: PollResponse) async { handler.mockNoReturn(args: [response]) }
    func pollerDidStop() { handler.mockNoReturn() }
    func poll(forceSynchronousProcessing: Bool) async throws -> PollResult<PollResponse> {
        return try handler.mockThrowing(args: [forceSynchronousProcessing])
    }
    func pollFromBackground() async throws -> PollResult<PollResponse> {
        return try handler.mockThrowing()
    }
    func nextPollDelay() async -> TimeInterval { return handler.mock() }
    func handlePollError(_ error: Error) async { handler.mockNoReturn(args: [error]) }
}
