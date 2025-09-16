// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit
import SessionNetworkingKit

// MARK: - Singleton

public extension Singleton {
    static let typingIndicators: SingletonConfig<TypingIndicators> = Dependencies.create(
        identifier: "typingIndicators",
        createInstance: { dependencies, _ in TypingIndicators(using: dependencies) }
    )
}

// MARK: - ThumbnailService

public actor TypingIndicators {
    // MARK: - Variables
    
    private let dependencies: Dependencies
    private var outgoing: [String: Indicator] = [:]
    private var incoming: [String: Indicator] = [:]
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
    }
    
    // MARK: - Functions
    
    public func startIfNeeded(
        threadId: String,
        threadVariant: SessionThread.Variant,
        direction: Direction,
        timestampMs: Int64?
    ) async {
        let targetIndicators: [String: Indicator] = (direction == .outgoing ? outgoing : incoming)
        
        /// If we already have an existing typing indicator for this thread then just refresh it's timeout (no need to do anything else)
        if let existingIndicator: Indicator = targetIndicators[threadId] {
            await existingIndicator.refreshTimeout(sentTimestampMs: timestampMs, using: dependencies)
            return
        }
        
        /// Create the indicator on the `timerQueue` if needed
        ///
        /// Typing indicators should only show/send 1-to-1 conversations that aren't blocked or message requests
        ///
        /// The `typingIndicatorsEnabled` flag reflects the user-facing setting in the app preferences, if it's disabled we don't
        /// want to emit "typing indicator" messages or show typing indicators for other users
        guard
            threadVariant == .contact &&
            dependencies.mutate(cache: .libSession, { libSession in
                libSession.get(.typingIndicatorsEnabled) &&
                !libSession.isContactBlocked(contactId: threadId) &&
                !libSession.isMessageRequest(threadId: threadId, threadVariant: threadVariant)
            })
        else { return }
        
        let newIndicator: Indicator = Indicator(
            threadId: threadId,
            threadVariant: threadVariant,
            direction: direction,
            timestampMs: (timestampMs ?? dependencies[cache: .snodeAPI].currentOffsetTimestampMs())
        )
        
        switch direction {
            case .outgoing: self.outgoing[threadId] = newIndicator
            case .incoming: self.incoming[threadId] = newIndicator
        }
        
        await newIndicator.start(using: dependencies)
    }
    
    public func didStopTyping(threadId: String, direction: Direction) async {
        switch direction {
            case .outgoing: await self.outgoing.removeValue(forKey: threadId)?.stop(using: dependencies)
            case .incoming: await self.incoming.removeValue(forKey: threadId)?.stop(using: dependencies)
        }
    }
    
    fileprivate func handleRefresh(threadId: String, threadVariant: SessionThread.Variant) async {
        try? await dependencies[singleton: .storage].writeAsync { db in
            try? MessageSender.send(
                db,
                message: TypingIndicator(kind: .started),
                interactionId: nil,
                threadId: threadId,
                threadVariant: threadVariant,
                using: self.dependencies
            )
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
        let threadId: String
        let threadVariant: SessionThread.Variant
        let direction: Direction
        let initialTimestampMs: Int64
        private var stopTask: Task<Void, Error>?
        private var refreshTask: Task<Void, Error>?
        
        init(
            threadId: String,
            threadVariant: SessionThread.Variant,
            direction: Direction,
            timestampMs: Int64
        ) {
            self.threadId = threadId
            self.threadVariant = threadVariant
            self.direction = direction
            self.initialTimestampMs = timestampMs
        }
        
        deinit {
            stopTask?.cancel()
            refreshTask?.cancel()
        }
        
        fileprivate func start(using dependencies: Dependencies) async {
            switch direction {
                case .outgoing: scheduleRefreshCallback(using: dependencies)
                case .incoming:
                    try? await dependencies[singleton: .storage].writeAsync { [threadId, initialTimestampMs] db in
                        try ThreadTypingIndicator(threadId: threadId, timestampMs: initialTimestampMs).upsert(db)
                        db.addTypingIndicatorEvent(threadId: threadId, change: .started)
                    }
            }
            
            await refreshTimeout(sentTimestampMs: initialTimestampMs, using: dependencies)
        }
        
        func stop(using dependencies: Dependencies) async {
            /// Need to run a detached task to cleanup the database record because we are about to cancel the `stopTask` and
            /// `refreshTask` (and if one of those triggered this call then the code would otherwise stop executing because the
            /// parent task is cancelled
            Task.detached { [threadId, threadVariant, direction, storage = dependencies[singleton: .storage]] in
                try? await storage.writeAsync { db in
                    switch direction {
                        case .outgoing:
                            try MessageSender.send(
                                db,
                                message: TypingIndicator(kind: .stopped),
                                interactionId: nil,
                                threadId: threadId,
                                threadVariant: threadVariant,
                                using: dependencies
                            )
                            
                        case .incoming:
                            _ = try ThreadTypingIndicator
                                .filter(ThreadTypingIndicator.Columns.threadId == threadId)
                                .deleteAll(db)
                            db.addTypingIndicatorEvent(threadId: threadId, change: .stopped)
                    }
                }
            }
            
            /// Now that the db cleanup is happening we can properly stop the tasks
            stopTask?.cancel()
            refreshTask?.cancel()
        }
        
        func refreshTimeout(sentTimestampMs: Int64?, using dependencies: Dependencies) async {
            stopTask?.cancel()
            
            let baseTimestamp: TimeInterval = (
                sentTimestampMs.map { TimeInterval(Double($0) / 1000) } ??
                dependencies.dateNow.timeIntervalSince1970
            )
            let delay: TimeInterval = TimeInterval(direction == .outgoing ? 3 : 15)

            stopTask = Task { [threadId, direction] in
                /// If the delay is in the future then we want to wait until then
                let timestampNow: TimeInterval = dependencies.dateNow.timeIntervalSince1970
                                                            
                if baseTimestamp + delay > timestampNow {
                    try await Task.sleep(for: .seconds(Int((baseTimestamp + delay) - timestampNow)))
                }
                
                try Task.checkCancellation()
                
                await dependencies[singleton: .typingIndicators].didStopTyping(
                    threadId: threadId,
                    direction: direction
                )
            }
        }
        
        private func scheduleRefreshCallback(using dependencies: Dependencies) {
            refreshTask?.cancel()
            
            refreshTask = Task { [threadId, threadVariant] in
                while !Task.isCancelled {
                    await dependencies[singleton: .typingIndicators].handleRefresh(
                        threadId: threadId,
                        threadVariant: threadVariant
                    )
                    try await Task.sleep(for: .seconds(10))
                }
            }
        }
    }
}
