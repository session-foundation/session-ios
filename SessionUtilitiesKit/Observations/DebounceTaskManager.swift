// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public actor DebounceTaskManager<Event: Sendable> {
    private let debounceInterval: DispatchTimeInterval
    private var debounceTask: Task<Void, Never>? = nil
    private var pendingEvents: [Event] = []
    private var pendingEventSet: Set<AnyHashable> = []
    private var action: (@Sendable ([Event]) async -> Void)?

    public init(debounceInterval: DispatchTimeInterval) {
        self.debounceInterval = debounceInterval
    }

    public func setAction(_ newAction: @Sendable @escaping ([Event]) async -> Void) {
        self.action = newAction
    }

    public func reset() {
        debounceTask?.cancel()
        debounceTask = nil
        pendingEvents.removeAll()
        pendingEventSet.removeAll()
        action = nil
    }
    
    // MARK: - Internal Functions

    fileprivate func scheduleSignal() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self = self else { return }
            guard !Task.isCancelled else { return }

            do {
                /// Only debounce if we want to
                if debounceInterval != .never {
                    try await Task.sleep(for: self.debounceInterval)
                }
                guard !Task.isCancelled else { return }
                
                let eventsToProcess: [Event] = await self.clearPendingEvents()
                
                /// Execute the `action` in a detached task so that it avoids inheriting any potential cancelled state from the calling
                /// task, since we capture `self` weakly we don't need to worry about it outliving the owning object either
                Task.detached { [weak self] in
                    await self?.action?(eventsToProcess)
                }
            } catch {
                // Task was cancelled so no need to do anything
            }
        }
    }
    
    fileprivate func flushPendingEvents() {
        debounceTask?.cancel()
        
        debounceTask = Task { [weak self] in
            guard let self = self else { return }
            guard !Task.isCancelled else { return }
            
            let eventsToProcess: [Event] = await self.clearPendingEvents()
            
            /// Execute the `action` in a detached task so that it avoids inheriting any potential cancelled state from the calling
            /// task, since we capture `self` weakly we don't need to worry about it outliving the owning object either
            Task.detached { [weak self] in
                await self?.action?(eventsToProcess)
            }
        }
    }
    
    private func clearPendingEvents() -> [Event] {
        let events: [Event] = pendingEvents
        pendingEvents.removeAll()
        pendingEventSet.removeAll()
        return events
    }
}

public extension DebounceTaskManager where Event == Void {
    func signal() {
        pendingEvents.append(())
        scheduleSignal()
    }
    
    func flush() {
        pendingEvents.append(())
        flushPendingEvents()
    }
}

public extension DebounceTaskManager {
    func signal(event: Event) {
        pendingEvents.append(event)
        scheduleSignal()
    }
    
    func flush(event: Event) {
        pendingEvents.append(event)
        flushPendingEvents()
    }
}

public extension DebounceTaskManager where Event: Hashable {
    func signal(event: Event) {
        /// Ignore duplicate events
        guard !pendingEventSet.contains(event) else { return }
        
        pendingEvents.append(event)
        pendingEventSet.insert(event)
        scheduleSignal()
    }
    
    func flush(event: Event) {
        /// Ignore duplicate events
        guard !pendingEventSet.contains(event) else { return }
        
        pendingEvents.append(event)
        pendingEventSet.insert(event)
        flushPendingEvents()
    }
}
