// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

public final class ClosedGroupPoller: Poller {
    public static var namespaces: [SnodeAPI.Namespace] = [.legacyClosedGroup]

    // MARK: - Settings
    
    override var namespaces: [SnodeAPI.Namespace] { ClosedGroupPoller.namespaces }
    override var pollerQueue: DispatchQueue { Threading.groupPollerQueue }
    override var pollDrainBehaviour: SwarmDrainBehaviour { .alwaysRandom }
    
    private static let minPollInterval: Double = 3
    private static let maxPollInterval: Double = 30

    // MARK: - Initialization
    
    public static let shared: ClosedGroupPoller = ClosedGroupPoller()

    // MARK: - Public API
    
    public func start(using dependencies: Dependencies = Dependencies()) {
        // Fetch all closed groups (excluding any don't contain the current user as a
        // GroupMemeber as the user is no longer a member of those)
        dependencies.storage
            .read { db in
                try ClosedGroup
                    .select(.threadId)
                    .joining(
                        required: ClosedGroup.members
                            .filter(GroupMember.Columns.profileId == getUserHexEncodedPublicKey(db, using: dependencies))
                    )
                    .asRequest(of: String.self)
                    .fetchAll(db)
            }
            .defaulting(to: [])
            .forEach { [weak self] publicKey in
                self?.startIfNeeded(for: publicKey, using: dependencies)
            }
    }

    // MARK: - Abstract Methods
    
    override public func pollerName(for publicKey: String) -> String {
        return "Closed group poller with public key: \(publicKey)"
    }

    override func nextPollDelay(for publicKey: String, using dependencies: Dependencies) -> TimeInterval {
        /// Get the received date of the last message in the thread. If we don't have any messages yet then use the group formation timestamp and,
        /// if that is unable to be retrieved for some reason, fallback to an activity of 1 hour
        let minActivityThreshold: TimeInterval = (5 * 60)
        let maxActivityThreshold: TimeInterval = (12 * 60 * 60)
        let fallbackActivityThreshold: TimeInterval = (1 * 60 * 60)
        let lastMessageDate: Date = Storage.shared
            .read { db in
                let lastMessageTimestmapMs: Int64? = try Interaction
                    .filter(Interaction.Columns.threadId == publicKey)
                    .select(.receivedAtTimestampMs)
                    .order(Interaction.Columns.timestampMs.desc)
                    .asRequest(of: Int64.self)
                    .fetchOne(db)
                
                switch lastMessageTimestmapMs {
                    case .some(let lastMessageTimestmapMs): return lastMessageTimestmapMs
                    case .none:
                        let formationTimestamp: TimeInterval? = try ClosedGroup
                            .filter(ClosedGroup.Columns.threadId == publicKey)
                            .select(.formationTimestamp)
                            .asRequest(of: TimeInterval.self)
                            .fetchOne(db)
                        
                        return formationTimestamp.map { Int64(floor($0 * 1000)) }
                }
            }
            .map { receivedAtTimestampMs -> Date? in
                guard receivedAtTimestampMs > 0 else { return nil }
                
                return Date(timeIntervalSince1970: (TimeInterval(receivedAtTimestampMs) / 1000))
            }
            .defaulting(to: dependencies.dateNow.addingTimeInterval(-fallbackActivityThreshold))
        
        /// Convert the conversation activity frequency into
        let timeSinceLastMessage: TimeInterval = dependencies.dateNow.timeIntervalSince(lastMessageDate)
        let conversationActivityInterval: TimeInterval = max(0, (timeSinceLastMessage - minActivityThreshold))
        let activityIntervalDelta: Double = (maxActivityThreshold - minActivityThreshold)
        let pollIntervalDelta: Double = (ClosedGroupPoller.maxPollInterval - ClosedGroupPoller.minPollInterval)
        let activityIntervalPercentage: Double = min(1, (conversationActivityInterval / activityIntervalDelta))
        
        return (ClosedGroupPoller.minPollInterval + (pollIntervalDelta * activityIntervalPercentage))
    }

    override func handlePollError(_ error: Error, for publicKey: String, using dependencies: Dependencies) -> PollerErrorResponse {
        return .continuePolling
    }
}
