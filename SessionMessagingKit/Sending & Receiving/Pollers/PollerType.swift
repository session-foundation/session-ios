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

public struct PollResult<PollResponse> {
    public let response: PollResponse
    public let rawMessageCount: Int
    public let validMessageCount: Int
    public let invalidMessageCount: Int
    public let hadValidHashUpdate: Bool
}

// MARK: - PollerType

public protocol PollerType: AnyObject {
    associatedtype PollResponse
    
    var dependencies: Dependencies { get }
    var pollerQueue: DispatchQueue { get }
    var pollerName: String { get }
    var pollerDestination: PollerDestination { get }
    var logStartAndStopCalls: Bool { get }
    nonisolated var receivedPollResponse: AsyncStream<PollResponse> { get }
    nonisolated var successfulPollCount: AsyncStream<Int> { get }
    
    var isPolling: Bool { get set }
    var pollCount: Int { get set }
    var failureCount: Int { get set }
    var lastPollStart: TimeInterval { get set }
    var cancellable: AnyCancellable? { get set }
    
    init(
        pollerName: String,
        pollerQueue: DispatchQueue,
        pollerDestination: PollerDestination,
        pollerDrainBehaviour: ThreadSafeObject<SwarmDrainBehaviour>,
        namespaces: [Network.SnodeAPI.Namespace],
        failureCount: Int,
        shouldStoreMessages: Bool,
        logStartAndStopCalls: Bool,
        customAuthMethod: AuthenticationMethod?,
        using dependencies: Dependencies
    )
    
    func startIfNeeded(forceStartInBackground: Bool)
    func stop()
    
    func pollerDidStart()
    func poll(forceSynchronousProcessing: Bool) -> AnyPublisher<PollResult<PollResponse>, Error>
    func nextPollDelay() -> AnyPublisher<TimeInterval, Error>
    func handlePollError(_ error: Error, _ lastError: Error?) -> PollerErrorResponse
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
                guard self?.isPolling != true else { return }
                
                // Might be a race condition that the setUpPolling finishes too soon,
                // and the timer is not created, if we mark the group as is polling
                // after setUpPolling. So the poller may not work, thus misses messages
                self?.isPolling = true
                self?.pollRecursively(nil)
                
                if self?.logStartAndStopCalls == true {
                    Log.info(.poller, "Started \(pollerName).")
                }
                
                self?.pollerDidStart()
            }
        }
    }
    
    func stop() {
        pollerQueue.async(using: dependencies) { [weak self, pollerName] in
            self?.isPolling = false
            self?.cancellable?.cancel()
            
            if self?.logStartAndStopCalls == true {
                Log.info(.poller, "Stopped \(pollerName).")
            }
        }
    }
    
    internal func pollRecursively(_ lastError: Error?) {
        guard isPolling else { return }
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
        
        self.lastPollStart = dependencies.dateNow.timeIntervalSince1970
        
        cancellable = poll(forceSynchronousProcessing: false)
            .subscribe(on: pollerQueue, using: dependencies)
            .receive(on: pollerQueue, using: dependencies)
            .asResult()
            .flatMapOptional { [weak self] value in self?.nextPollDelay().map { (value, $0) } }
            .sink(
                receiveCompletion: { _ in },    // Never called
                receiveValue: { [weak self, pollerName, pollerQueue, lastPollStart, failureCount, dependencies] result, nextPollDelay in
                    // If the polling has been cancelled then don't continue
                    guard self?.isPolling == true else { return }
                    
                    let endTime: TimeInterval = dependencies.dateNow.timeIntervalSince1970
                    let duration: TimeUnit = .seconds(endTime - lastPollStart)
                    let nextPollInterval: TimeUnit = .seconds(nextPollDelay)
                    var errorFromPoll: Error?
                    
                    // Log information about the poll
                    switch result {
                        case .failure(let error):
                            // Increment the failure count
                            self?.failureCount = (failureCount + 1)
                            errorFromPoll = error
                            
                            // Determine if the error should stop us from polling anymore
                            switch self?.handlePollError(error, lastError) {
                                case .stopPolling: return
                                case .continuePollingInfo(let info):
                                    Log.error(.poller, "\(pollerName) failed to process any messages after \(duration, unit: .s) due to error: \(error). \(info). Setting failure count to \(failureCount). Next poll in \(nextPollInterval, unit: .s).")
                                    
                                case .continuePolling, .none:
                                    Log.error(.poller, "\(pollerName) failed to process any messages after \(duration, unit: .s) due to error: \(error). Setting failure count to \(failureCount). Next poll in \(nextPollInterval, unit: .s).")
                            }
                            
                        case .success(let response):
                            // Reset the failure count
                            self?.failureCount = 0
                            
                            if response.rawMessageCount == 0 {
                                Log.info(.poller, "Received no new messages in \(pollerName) after \(duration, unit: .s). Next poll in \(nextPollInterval, unit: .s).")
                            }
                            else {
                                let duplicateCount: Int = (response.rawMessageCount - response.validMessageCount - response.invalidMessageCount)
                                var details: [String] = []
                                
                                if response.validMessageCount > 0 {
                                    details.append("valid: \(response.validMessageCount)")
                                }
                                if response.invalidMessageCount > 0 {
                                    details.append("invalid: \(response.invalidMessageCount)")
                                }
                                if duplicateCount > 0 {
                                    details.append("duplicates: \(duplicateCount)")
                                }
                                
                                let detailsString: String = (details.isEmpty ? "" : " (\(details.joined(separator: ", ")))")
                                let hashNote: String = (response.validMessageCount == 0 && response.invalidMessageCount == 0 && !response.hadValidHashUpdate ? " - marked the hash we polled with as invalid" : "")
                                
                                Log.info(.poller, "Received \(response.rawMessageCount) new message(s) in \(pollerName) after \(duration, unit: .s)\(detailsString)\(hashNote). Next poll in \(nextPollInterval, unit: .s).")
                            }
                    }
                    
                    // Schedule the next poll
                    pollerQueue.asyncAfter(deadline: .now() + .milliseconds(Int(nextPollInterval.timeInterval * 1000)), qos: .default, using: dependencies) {
                        self?.pollRecursively(errorFromPoll)
                    }
                }
            )
    }
    
    /// This doesn't do anything functional _but_ does mean if we get a crash from the `BackgroundPoller` we can better distinguish
    /// it from a crash from a foreground poll
    func pollFromBackground() -> AnyPublisher<PollResult<PollResponse>, Error> {
        return poll(forceSynchronousProcessing: true)
    }
}
