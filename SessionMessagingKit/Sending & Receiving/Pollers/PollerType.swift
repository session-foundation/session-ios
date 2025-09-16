// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import SessionNetworkingKit
import SessionUtilitiesKit

// MARK: - Log.Category

public extension Log.Category {
    static let poller: Log.Category = .create("Poller", defaultLevel: .info)
}

// MARK: - PollerDestination

public enum PollerDestination: Sendable, Equatable {
    case swarm(String)
    case server(String)
    
    public var target: String {
        switch self {
            case .swarm(let value), .server(let value): return value
        }
    }
}

// MARK: - PollResult

public struct PollResult<R> {
    public let response: R
    public let rawMessageCount: Int
    public let validMessageCount: Int
    public let hadValidHashUpdate: Bool
    
    public init(
        _ response: R,
        _ rawMessageCount: Int = 0,
        _ validMessageCount: Int = 0,
        _ hadValidHashUpdate: Bool = false
    ) {
        self.response = response
        self.rawMessageCount = rawMessageCount
        self.validMessageCount = validMessageCount
        self.hadValidHashUpdate = hadValidHashUpdate
    }
}

// MARK: - PollerType

public protocol PollerType: Actor {
    associatedtype PollResponse
    
    var dependencies: Dependencies { get }
    var dependenciesKey: Dependencies.Key? { get }
    var pollerName: String { get }
    var destination: PollerDestination { get }
    var logStartAndStopCalls: Bool { get }
    nonisolated var receivedPollResponse: AsyncStream<PollResponse> { get }
    
    var pollCount: Int { get set }
    var failureCount: Int { get set }
    var lastPollStart: TimeInterval { get set }
    var pollTask: Task<Void, Error>? { get set }
    
    init(
        pollerName: String,
        destination: PollerDestination,
        swarmDrainStrategy: SwarmDrainer.Strategy,
        namespaces: [SnodeAPI.Namespace],
        failureCount: Int,
        shouldStoreMessages: Bool,
        logStartAndStopCalls: Bool,
        customAuthMethod: AuthenticationMethod?,
        key: Dependencies.Key?,
        using dependencies: Dependencies
    )
    
    func startIfNeeded(forceStartInBackground: Bool) async
    func stop()
    
    func pollerDidStart()
    func pollerReceivedResponse(_ response: PollResponse) async
    func pollerDidStop()
    func poll(forceSynchronousProcessing: Bool) async throws -> PollResult<PollResponse>
    func pollFromBackground() async throws -> PollResult<PollResponse>
    func nextPollDelay() async -> TimeInterval
    func handlePollError(_ error: Error) async
}

// MARK: - Default Implementations

public extension PollerType {
    func startIfNeeded() async { await startIfNeeded(forceStartInBackground: false) }
    
    func startIfNeeded(forceStartInBackground: Bool) async {
        var canStartWhenInactive: Bool = forceStartInBackground
        
        if !canStartWhenInactive {
            canStartWhenInactive = await dependencies[singleton: .appContext].isMainAppAndActive
        }
        
        guard canStartWhenInactive else {
            return Log.info(.poller, "Ignoring call to start \(pollerName) due to not being active.")
        }
        
        guard pollTask == nil else { return }
        
        pollTask = Task { [weak self] in
            guard let self = self else { return }
            
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await self.pollRecursively() }
                    group.addTask { try await self.listenForReplacement() }
                    
                    /// Wait until one of the groups completes or errors
                    for try await _ in group {}
                }
            }
            catch { await stop() }
        }
        
        if logStartAndStopCalls {
            Log.info(.poller, "Started \(pollerName).")
        }
        
        pollerDidStart()
    }
    
    func stop() {
        pollTask?.cancel()
        pollTask = nil
        
        if logStartAndStopCalls {
            Log.info(.poller, "Stopped \(pollerName).")
        }
        
        pollerDidStop()
    }
    
    private func pollRecursively() async throws {
        typealias TimeInfo = (
            duration: TimeUnit,
            nextPollDelay: TimeInterval,
            nextPollInterval: TimeUnit
        )
        
        /// Don't bother trying to poll if we don't have a network connection, just wait for one to be established
        try await dependencies.waitUntilConnected(
            onWillStartWaiting: { [pollerName] in
                Log.info(.poller, "\(pollerName) waiting for network to connect before starting to poll.")
            },
            retryDelayProvider: self.nextPollDelay
        )
        
        /// Now that we have a connection just poll indefinitely
        while true {
            try Task.checkCancellation()
            
            guard
                !dependencies[singleton: .storage].isSuspended,
                await dependencies[singleton: .network].isSuspended == false
            else {
                let suspendedDependency: String = {
                    guard !dependencies[singleton: .storage].isSuspended else {
                        return "storage"
                    }
                    
                    return "network"
                }()
                Log.warn(.poller, "Stopped \(pollerName) due to \(suspendedDependency) being suspended.")
                stop()
                return
            }
            
            lastPollStart = dependencies.dateNow.timeIntervalSince1970
            let getTimeInfo: (TimeInterval, Dependencies) async throws -> TimeInfo = { lastPollStart, dependencies in
                let endTime: TimeInterval = dependencies.dateNow.timeIntervalSince1970
                let duration: TimeUnit = .seconds(endTime - lastPollStart)
                let nextPollDelay: TimeInterval = await self.nextPollDelay()
                let nextPollInterval: TimeUnit = .seconds(nextPollDelay)
                
                return (duration, nextPollDelay, nextPollInterval)
            }
            var timeInfo: TimeInfo = try await getTimeInfo(lastPollStart, dependencies)
            
            do {
                let result: PollResult<PollResponse> = try await poll(forceSynchronousProcessing: false)
                try Task.checkCancellation()
                
                /// Notify any observers that we got a result
                await pollerReceivedResponse(result.response)
                
                /// Reset the failure count
                failureCount = 0
                timeInfo = try await getTimeInfo(lastPollStart, dependencies)
                
                /// Log the poll result
                switch (result.rawMessageCount, result.validMessageCount, result.hadValidHashUpdate) {
                    case (0, _, _):
                        Log.info(.poller, "Received no new messages in \(pollerName) after \(timeInfo.duration, unit: .s). Next poll in \(timeInfo.nextPollInterval, unit: .s).")
                        
                    case (_, 0, false):
                        Log.info(.poller, "Received \(result.rawMessageCount) new message(s) in \(pollerName) after \(timeInfo.duration, unit: .s), all duplicates - marked the hash we polled with as invalid. Next poll in \(timeInfo.nextPollInterval, unit: .s).")
                        
                    default:
                        Log.info(.poller, "Received \(result.validMessageCount) new message(s) in \(pollerName) after \(timeInfo.duration, unit: .s) (duplicates: \(result.rawMessageCount - result.validMessageCount)). Next poll in \(timeInfo.nextPollInterval, unit: .s).")
                }
            }
            catch is CancellationError {
                /// If we were cancelled then we don't want to continue
                break
            }
            catch {
                try Task.checkCancellation()
                
                /// Increment the failure count and log the error
                failureCount = failureCount + 1
                timeInfo = try await getTimeInfo(lastPollStart, dependencies)
                Log.error(.poller, "\(pollerName) failed to process any messages after \(timeInfo.duration, unit: .s) due to error: \(error). Setting failure count to \(failureCount). Next poll in \(timeInfo.nextPollInterval, unit: .s).")
                
                /// Perform any custom error handling
                await handlePollError(error)
            }
            
            /// Sleep until the next poll
            try await Task.sleep(for: .milliseconds(Int(timeInfo.nextPollDelay * 1000)))
        }
    }
    
    private func listenForReplacement() async throws {
        guard let key: Dependencies.Key = dependenciesKey else { return }
        
        for await changedValue in dependencies.stream(key: key, of: (any PollerType).self) {
            if ObjectIdentifier(changedValue as AnyObject) != ObjectIdentifier(self as AnyObject) {
                Log.info(.poller, "\(pollerName) has been replaced in dependencies, shutting down old instance.")
                pollTask?.cancel()
                break
            }
        }
    }
    
    /// This doesn't do anything functional _but_ does mean if we get a crash from the `BackgroundPoller` we can better distinguish
    /// it from a crash from a foreground poll
    func pollFromBackground() async throws -> PollResult<PollResponse> {
        return try await poll(forceSynchronousProcessing: true)
    }
    
    func handlePollError(_ error: Error) async {}
}
