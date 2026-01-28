// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import SessionUIKit
import SessionNetworkingKit
import SessionUtilitiesKit

// MARK: - Log.Category

public extension Log.Category {
    static let poller: Log.Category = .create("Poller", defaultLevel: .info)
}

// MARK: - PollerDestination

public enum PollerDestination {
    case swarm(String)
    case server(String)
    
    public var target: String {
        switch self {
            case .swarm(let value), .server(let value): return value
        }
    }
}

// MARK: - PollerErrorResponse

public enum PollerErrorResponse {
    case stopPolling
    case continuePolling
    case continuePollingInfo(String)
}

// MARK: - PollResult

public struct PollResult<R> {
    public let response: R
    public let rawMessageCount: Int
    public let validMessageCount: Int
    public let invalidMessageCount: Int
    public let hadValidHashUpdate: Bool
    
    public init(
        response: R,
        rawMessageCount: Int = 0,
        validMessageCount: Int = 0,
        invalidMessageCount: Int = 0,
        hadValidHashUpdate: Bool = false
    ) {
        self.response = response
        self.rawMessageCount = rawMessageCount
        self.validMessageCount = validMessageCount
        self.invalidMessageCount = invalidMessageCount
        self.hadValidHashUpdate = hadValidHashUpdate
    }
}

// MARK: - PollerType

public protocol PollerType: AnyObject {
    associatedtype PollResponse
    
    var dependencies: Dependencies { get }
    var dependenciesKey: Dependencies.Key? { get }
    var pollerQueue: DispatchQueue { get }
    var pollerName: String { get }
    var pollerDestination: PollerDestination { get }
    var logStartAndStopCalls: Bool { get }
    nonisolated var receivedPollResponse: AsyncStream<PollResponse> { get }
    nonisolated var successfulPollCount: AsyncStream<Int> { get }
    
    var pollTask: Task<Void, Error>? { get set }
    var pollCount: Int { get set }
    var failureCount: Int { get set }
    var lastPollStart: TimeInterval { get set }
    
    init(
        pollerName: String,
        pollerQueue: DispatchQueue,
        pollerDestination: PollerDestination,
        swarmDrainStrategy: SwarmDrainer.Strategy,
        namespaces: [Network.SnodeAPI.Namespace],
        failureCount: Int,
        shouldStoreMessages: Bool,
        logStartAndStopCalls: Bool,
        customAuthMethod: AuthenticationMethod?,
        key: Dependencies.Key?,
        using dependencies: Dependencies
    )
    
    func startIfNeeded(forceStartInBackground: Bool)
    func stop()
    
    func pollerDidStart()
    func poll(forceSynchronousProcessing: Bool) async throws -> PollResult<PollResponse>
    func nextPollDelay() async -> TimeInterval
    func handlePollError(_ error: Error) async
}

// MARK: - Default Implementations

public extension PollerType {
    func startIfNeeded() { startIfNeeded(forceStartInBackground: false) }
    
    func startIfNeeded(forceStartInBackground: Bool) {
        Task { @MainActor [weak self, pollerName, pollerQueue, appContext = dependencies[singleton: .appContext], dependencies] in
            guard
                forceStartInBackground ||
                appContext.isMainAppAndActive
            else { return Log.info(.poller, "Ignoring call to start \(pollerName) due to not being active.") }
            
            pollerQueue.async(using: dependencies) { [weak self] in
                guard self?.pollTask == nil else { return }
                
                self?.pollTask = Task { [weak self] in
                    guard let self = self else { return }
                    
                    do {
                        try await withThrowingTaskGroup(of: Void.self) { group in
                            group.addTask { try await self.pollRecursively() }
                            group.addTask { try await self.listenForReplacement() }
                            
                            /// Wait until one of the groups completes or errors
                            for try await _ in group {}
                        }
                    }
                    catch { stop() }
                }
                
                if self?.logStartAndStopCalls == true {
                    Log.info(.poller, "Started \(pollerName).")
                }
                
                self?.pollerDidStart()
            }
        }
    }
    
    func stop() {
        pollerQueue.async(using: dependencies) { [weak self, pollerName] in
            self?.pollTask?.cancel()
            self?.pollTask = nil
            
            if self?.logStartAndStopCalls == true {
                Log.info(.poller, "Stopped \(pollerName).")
            }
        }
    }
    
    private func pollRecursively() async throws {
        typealias TimeInfo = (
            duration: TimeUnit,
            nextPollDelay: TimeInterval,
            nextPollInterval: TimeUnit
        )
        
        while true {
            guard
                !dependencies[singleton: .storage].isSuspended &&
                    !dependencies[cache: .libSessionNetwork].isSuspended
            else {
                let suspendedDependency: String = {
                    guard !dependencies[singleton: .storage].isSuspended else {
                        return "storage"
                    }
                    
                    return "network"
                }()
                Log.warn(.poller, "Stopped \(pollerName) due to \(suspendedDependency) being suspended.")
                self.stop()
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
            try Task.checkCancellation()
            
            do {
                let result: PollResult<PollResponse> = try await poll(forceSynchronousProcessing: false)
                try Task.checkCancellation()
                
                /// Reset the failure count
                failureCount = 0
                timeInfo = try await getTimeInfo(lastPollStart, dependencies)
                
                if result.rawMessageCount == 0 {
                    Log.info(.poller, "Received no new messages in \(pollerName) after \(timeInfo.duration, unit: .s). Next poll in \(timeInfo.nextPollInterval, unit: .s).")
                }
                else {
                    let duplicateCount: Int = (result.rawMessageCount - result.validMessageCount - result.invalidMessageCount)
                    var details: [String] = []
                    
                    if result.validMessageCount > 0 {
                        details.append("valid: \(result.validMessageCount)")
                    }
                    if result.invalidMessageCount > 0 {
                        details.append("invalid: \(result.invalidMessageCount)")
                    }
                    if duplicateCount > 0 {
                        details.append("duplicates: \(duplicateCount)")
                    }
                    
                    let detailsString: String = (details.isEmpty ? "" : " (\(details.joined(separator: ", ")))")
                    let hashNote: String = (result.validMessageCount == 0 && result.invalidMessageCount == 0 && !result.hadValidHashUpdate ? " - marked the hash we polled with as invalid" : "")
                    
                    Log.info(.poller, "Received \(result.rawMessageCount) new message(s) in \(pollerName) after \(timeInfo.duration, unit: .s)\(detailsString)\(hashNote). Next poll in \(timeInfo.nextPollInterval, unit: .s).")
                }
            }
            catch is CancellationError {
                /// If we were cancelled then we don't want to continue to loop
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
        
        if #available(iOS 16.0, *) {
            for await changedValue in dependencies.stream(key: key, of: (any PollerType).self) {
                if ObjectIdentifier(changedValue as AnyObject) != ObjectIdentifier(self as AnyObject) {
                    Log.info(.poller, "\(pollerName) has been replaced in dependencies, shutting down old instance.")
                    pollTask?.cancel()
                    break
                }
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
