// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit
import SessionSnodeKit

// MARK: - Singleton

public extension Singleton {
    static let typingIndicators: SingletonConfig<TypingIndicators> = Dependencies.create(
        identifier: "typingIndicators",
        createInstance: { dependencies in TypingIndicators(using: dependencies) }
    )
}

// MARK: - ThumbnailService

public class TypingIndicators {
    // MARK: - Variables
    
    private let dependencies: Dependencies
    @ThreadSafeObject private var timerQueue: DispatchQueue = DispatchQueue(
        label: "org.getsession.typingIndicatorQueue",   // stringlint:ignore
        qos: .userInteractive
    )
    @ThreadSafeObject private var outgoing: [String: Indicator] = [:]
    @ThreadSafeObject private var incoming: [String: Indicator] = [:]
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
    }
    
    // MARK: - Functions
    
    public func startIfNeeded(
        threadId: String,
        threadVariant: SessionThread.Variant,
        threadIsBlocked: Bool,
        threadIsMessageRequest: Bool,
        direction: Direction,
        timestampMs: Int64?
    ) {
        let targetIndicators: [String: Indicator] = (direction == .outgoing ? outgoing : incoming)
        
        /// If we already have an existing typing indicator for this thread then just refresh it's timeout (no need to do anything else)
        if let existingIndicator: Indicator = targetIndicators[threadId] {
            existingIndicator.refreshTimeout(timerQueue: timerQueue, using: dependencies)
            return
        }
        
        /// Create the indicator on the `timerQueue` if needed
        ///
        /// Typing indicators should only show/send 1-to-1 conversations that aren't blocked or message requests
        ///
        /// The `typingIndicatorsEnabled` flag reflects the user-facing setting in the app preferences, if it's disabled we don't
        /// want to emit "typing indicator" messages or show typing indicators for other users
        ///
        /// **Note:** We do this check on a background thread because, while it's just checking a setting, we are still accessing the
        /// database to check `typingIndicatorsEnabled` so want to avoid doing it on the main thread
        timerQueue.async { [weak self, dependencies] in
            guard
                threadVariant == .contact &&
                !threadIsBlocked &&
                !threadIsMessageRequest &&
                dependencies[singleton: .storage, key: .typingIndicatorsEnabled],
                let timerQueue: DispatchQueue = self?.timerQueue
            else { return }
            
            let newIndicator: Indicator = Indicator(
                threadId: threadId,
                threadVariant: threadVariant,
                direction: direction,
                timestampMs: (timestampMs ?? dependencies[cache: .snodeAPI].currentOffsetTimestampMs())
            )
            
            switch direction {
                case .outgoing: self?._outgoing.performUpdate { $0.setting(threadId, newIndicator) }
                case .incoming: self?._incoming.performUpdate { $0.setting(threadId, newIndicator) }
            }
            
            dependencies[singleton: .storage].writeAsync { db in
                newIndicator.start(db, timerQueue: timerQueue, using: dependencies)
            }
        }
    }
    
    public func didStopTyping(_ db: Database, threadId: String, direction: Direction) {
        switch direction {
            case .outgoing:
                if let indicator: Indicator = outgoing[threadId] {
                    indicator.stop(db, using: dependencies)
                    _outgoing.performUpdate { $0.removingValue(forKey: threadId) }
                }
                
            case .incoming:
                if let indicator: Indicator = incoming[threadId] {
                    indicator.stop(db, using: dependencies)
                    _incoming.performUpdate { $0.removingValue(forKey: threadId) }
                }
        }
    }
}

public extension TypingIndicators {
    // MARK: - Direction
    
    enum Direction {
        case outgoing
        case incoming
    }
    
    // MARK: - Indicator
    
    class Indicator {
        fileprivate let threadId: String
        fileprivate let threadVariant: SessionThread.Variant
        fileprivate let direction: Direction
        fileprivate let timestampMs: Int64
        fileprivate var refreshTimer: DispatchSourceTimer?
        fileprivate var stopTimer: DispatchSourceTimer?
        
        init(
            threadId: String,
            threadVariant: SessionThread.Variant,
            direction: Direction,
            timestampMs: Int64
        ) {
            self.threadId = threadId
            self.threadVariant = threadVariant
            self.direction = direction
            self.timestampMs = timestampMs
        }
        
        fileprivate func start(_ db: Database, timerQueue: DispatchQueue, using dependencies: Dependencies) {
            // Start the typing indicator
            switch direction {
                case .outgoing: scheduleRefreshCallback(timerQueue: timerQueue, using: dependencies)
                case .incoming:
                    try? ThreadTypingIndicator(
                        threadId: threadId,
                        timestampMs: timestampMs
                    )
                    .upsert(db)
            }
            
            // Refresh the timeout since we just started
            refreshTimeout(timerQueue: timerQueue, using: dependencies)
        }
        
        fileprivate func stop(_ db: Database, using dependencies: Dependencies) {
            self.refreshTimer?.cancel()
            self.refreshTimer = nil
            self.stopTimer?.cancel()
            self.stopTimer = nil
            
            switch direction {
                case .outgoing:
                    try? MessageSender.send(
                        db,
                        message: TypingIndicator(kind: .stopped),
                        interactionId: nil,
                        threadId: threadId,
                        threadVariant: threadVariant,
                        using: dependencies
                    )
                    
                case .incoming:
                    _ = try? ThreadTypingIndicator
                        .filter(ThreadTypingIndicator.Columns.threadId == self.threadId)
                        .deleteAll(db)
            }
        }
        
        fileprivate func refreshTimeout(timerQueue: DispatchQueue, using dependencies: Dependencies) {
            let threadId: String = self.threadId
            let direction: Direction = self.direction
            
            // Schedule the 'stopCallback' to cancel the typing indicator
            stopTimer?.cancel()
            stopTimer = DispatchSource.makeTimerSource(queue: timerQueue)
            stopTimer?.schedule(deadline: .now() + .seconds(direction == .outgoing ? 3 : 15))
            stopTimer?.setEventHandler {
                dependencies[singleton: .storage].writeAsync { db in
                    dependencies[singleton: .typingIndicators].didStopTyping(
                        db,
                        threadId: threadId,
                        direction: direction
                    )
                }
            }
            stopTimer?.resume()
        }
        
        private func scheduleRefreshCallback(
            timerQueue: DispatchQueue,
            using dependencies: Dependencies
        ) {
            refreshTimer?.cancel()
            refreshTimer = DispatchSource.makeTimerSource(queue: timerQueue)
            refreshTimer?.schedule(deadline: .now(), repeating: .seconds(10))
            refreshTimer?.setEventHandler { [threadId = self.threadId, threadVariant = self.threadVariant] in
                dependencies[singleton: .storage].writeAsync { db in
                    try? MessageSender.send(
                        db,
                        message: TypingIndicator(kind: .started),
                        interactionId: nil,
                        threadId: threadId,
                        threadVariant: threadVariant,
                        using: dependencies
                    )
                }
            }
            refreshTimer?.resume()
        }
    }
}
