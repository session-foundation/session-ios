// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionNetworkingKit
import SessionUtilitiesKit

// MARK: - Cache

public extension Singleton {
    static let groupPollerManager: SingletonConfig<GroupPollerManagerType> = Dependencies.create(
        identifier: "groupPollerManager",
        createInstance: { dependencies in GroupPollerManager(using: dependencies) }
    )
}

// MARK: - GroupPoller

public actor GroupPoller: SwarmPollerType {
    private let minPollInterval: Double = 3
    private let maxPollInterval: Double = 30
    
    public static func namespaces(swarmPublicKey: String) -> [SnodeAPI.Namespace] {
        guard (try? SessionId.Prefix(from: swarmPublicKey)) == .group else {
            return [.legacyClosedGroup]
        }
        
        return [
            .groupMessages,
            .configGroupInfo,
            .configGroupMembers,
            .configGroupKeys,
            .revokedRetrievableGroupMessages
        ]
    }
    
    public let dependencies: Dependencies
    public let pollerName: String
    public let destination: PollerDestination
    public let swarmDrainer: SwarmDrainer
    public let logStartAndStopCalls: Bool
    nonisolated public var receivedPollResponse: AsyncStream<PollResponse> { responseStream.stream }
    
    public var pollTask: Task<Void, any Error>?
    public var pollCount: Int = 0
    public var failureCount: Int
    public var lastPollStart: TimeInterval = 0
    public var cancellable: AnyCancellable?
    
    public let namespaces: [SnodeAPI.Namespace]
    public let customAuthMethod: AuthenticationMethod?
    public let shouldStoreMessages: Bool
    nonisolated private let responseStream: CancellationAwareAsyncStream<PollResponse> = CancellationAwareAsyncStream()
    
    // MARK: - Initialization

    public init(
        pollerName: String,
        destination: PollerDestination,
        swarmDrainStrategy: SwarmDrainer.Strategy,
        namespaces: [SnodeAPI.Namespace],
        failureCount: Int,
        shouldStoreMessages: Bool,
        logStartAndStopCalls: Bool,
        customAuthMethod: AuthenticationMethod?,
        using dependencies: Dependencies
    ) {
        let (stream, continuation) = AsyncStream<PollResponse>.makeStream()
        self.dependencies = dependencies
        self.pollerName = pollerName
        self.destination = destination
        self.swarmDrainer = SwarmDrainer(
            strategy: swarmDrainStrategy,
            nextRetrievalAfterDrain: .resetState,
            logDetails: SwarmDrainer.LogDetails(cat: .poller, name: pollerName),
            using: dependencies
        )
        self.namespaces = namespaces
        self.failureCount = failureCount
        self.customAuthMethod = customAuthMethod
        self.shouldStoreMessages = shouldStoreMessages
        self.logStartAndStopCalls = logStartAndStopCalls
    }

    deinit {
        // Send completion events to the observables
        Task { [stream = responseStream] in
            await stream.finishCurrentStreams()
        }
        
        pollTask?.cancel()
    }
    
    // MARK: - Polling
    
    public func pollerDidStart() {
        guard
            let sessionId: SessionId = try? SessionId(from: destination.target),
            sessionId.prefix == .group
        else { return }
        
        let numKeys: Int = dependencies
            .mutate(cache: .libSession) { $0.config(for: .groupKeys, sessionId: sessionId)?.count }
            .defaulting(to: 0)
        
        /// If the keys generation is greated than `0` then it means we have a valid config so shouldn't continue
        guard numKeys == 0 else { return }
        
        Task { [destination, dependencies] in
            let isExpired: Bool? = try await dependencies[singleton: .storage].readAsync { [destination] db in
                try ClosedGroup
                    .filter(id: destination.target)
                    .select(.expired)
                    .asRequest(of: Bool.self)
                    .fetchOne(db)
            }
            
            /// If we haven't set the `expired` value then we should check the first poll response to see if it's missing the
            /// `GroupKeys` config message
            guard
                isExpired != true,
                let response: PollResponse = await receivedPollResponse.first(where: { _ in true }),
                !response.contains(where: { $0.namespace == .configGroupKeys })
            else { return }
            
            /// There isn't `GroupKeys` config so flag the group as `expired`
            Log.error(.poller, "\(pollerName) received no config messages in it's first poll, flagging as expired.")
            try await dependencies[singleton: .storage].writeAsync { db in
                try ClosedGroup
                    .filter(id: destination.target)
                    .updateAllAndConfig(
                        db,
                        ClosedGroup.Columns.expired.set(to: true),
                        using: dependencies
                    )
            }
        }
    }
    
    public func pollerReceivedResponse(_ response: PollResponse) async {
        await responseStream.send(response)
    }
    
    public func pollerDidStop() {
        Task { await responseStream.finishCurrentStreams() }
    }
    
    // MARK: - PollerType

    public func nextPollDelay() async -> TimeInterval {
        let lastReadDate: Date = dependencies
            .mutate(cache: .libSession) { cache in
                cache.conversationLastRead(
                    threadId: destination.target,
                    threadVariant: .group,
                    openGroupUrlInfo: nil
                )
            }
            .map { lastReadTimestampMs in
                guard lastReadTimestampMs > 0 else { return nil }
                
                return Date(timeIntervalSince1970: TimeInterval(Double(lastReadTimestampMs) / 1000))
            }
            .defaulting(to: dependencies.dateNow.addingTimeInterval(-5 * 60))
        
        /// Get the received date of the last message in the thread. If we don't have any messages yet, pick some reasonable fake time
        /// interval to use instead
        let receivedAtTimestampMs: Int64? = try? await dependencies[singleton: .storage].readAsync { [destination] db in
            try Interaction
                .filter(Interaction.Columns.threadId == destination.target)
                .select(.receivedAtTimestampMs)
                .order(Interaction.Columns.timestampMs.desc)
                .asRequest(of: Int64.self)
                .fetchOne(db)
        }
        let lastMessageDate: Date = {
            guard
                let receivedAtTimestampMs: Int64 = receivedAtTimestampMs,
                receivedAtTimestampMs > 0
            else { return dependencies.dateNow.addingTimeInterval(-5 * 60) }
            
            return Date(timeIntervalSince1970: TimeInterval(Double(receivedAtTimestampMs) / 1000))
        }()
        
        let timeSinceLastMessage: TimeInterval = dependencies.dateNow
            .timeIntervalSince(max(lastMessageDate, lastReadDate))
        let limit: Double = (12 * 60 * 60)
        let a: TimeInterval = ((maxPollInterval - minPollInterval) / limit)
        let nextPollInterval: TimeInterval = a * min(timeSinceLastMessage, limit) + minPollInterval
        
        return nextPollInterval
    }
}

// MARK: - GroupPollerManager

public actor GroupPollerManager: GroupPollerManagerType {
    private let dependencies: Dependencies
    private var pollers: [String: GroupPoller] = [:] // One for each swarm
    
    // MARK: - Initialization
    
    public init(using dependencies: Dependencies) {
        self.dependencies = dependencies
    }
    
    deinit {
        Task { [pollers] in
            for poller in pollers.values {
                await poller.stop()
            }
        }
    }
    
    // MARK: - Functions
    
    public func startAllPollers() async {
        Task {
            let groupPublicKeys: Set<String> = try await dependencies[singleton: .storage].readAsync { db in
                try ClosedGroup
                    .select(.threadId)
                    .filter(ClosedGroup.Columns.shouldPoll == true)
                    .filter(
                        ClosedGroup.Columns.threadId > SessionId.Prefix.group.rawValue &&
                        ClosedGroup.Columns.threadId < SessionId.Prefix.group.endOfRangeString
                    )
                    .asRequest(of: String.self)
                    .fetchSet(db)
            }
            
            for swarmPublicKey in groupPublicKeys {
                await getOrCreatePoller(for: swarmPublicKey).startIfNeeded()
            }
        }
    }
    
    @discardableResult public func getOrCreatePoller(for swarmPublicKey: String) async -> any SwarmPollerType {
        guard let poller: GroupPoller = pollers[swarmPublicKey.lowercased()] else {
            let poller: GroupPoller = GroupPoller(
                pollerName: "Closed group poller with public key: \(swarmPublicKey)", // stringlint:ignore
                destination: .swarm(swarmPublicKey),
                swarmDrainStrategy: .alwaysRandom,
                namespaces: GroupPoller.namespaces(swarmPublicKey: swarmPublicKey),
                shouldStoreMessages: true,
                logStartAndStopCalls: false,
                using: dependencies
            )
            pollers[swarmPublicKey.lowercased()] = poller
            return poller
        }
        
        return poller
    }
    
    public func stopAndRemovePoller(for swarmPublicKey: String) async {
        await pollers[swarmPublicKey.lowercased()]?.stop()
        pollers[swarmPublicKey.lowercased()] = nil
    }
    
    public func stopAndRemoveAllPollers() async {
        for poller in pollers.values {
            await poller.stop()
        }
        
        pollers.removeAll()
    }
}

// MARK: - GroupPollerManagerType

public protocol GroupPollerManagerType {
    func startAllPollers() async
    @discardableResult func getOrCreatePoller(for swarmPublicKey: String) async -> any SwarmPollerType
    func stopAndRemovePoller(for swarmPublicKey: String) async
    func stopAndRemoveAllPollers() async
}
