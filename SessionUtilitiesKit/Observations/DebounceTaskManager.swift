// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public actor DebounceTaskManager<Event: Sendable> {
    /// The way observations work is by sending a bunch of individual "change" events, this `DebounceTaskManager` then batches
    /// them together and sends through the grouped changes at once (allowing us to reduce the number of queries/renders that occur
    /// when many events happen in a short period).
    ///
    /// The interval needs to be long enough to be able to group different events that could be triggered by an action (db write, async
    /// tasks, actor hopping, etc.) but not so long that the user might perceive some lag after performing an action that should trigger a
    /// UI update.
    private let debounceInterval: DispatchTimeInterval = .milliseconds(25)
    
    private var debounceTask: Task<Void, Never>? = nil
    private var pendingEvents: [Event] = []
    private var pendingEventSet: Set<AnyHashable> = []
    private var action: (@Sendable ([Event]) async -> Void)?

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
        debounceTask = Task(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            guard !Task.isCancelled else { return }

            do {
                try await Task.sleep(for: self.debounceInterval)
                guard !Task.isCancelled else { return }
                
                let eventsToProcess: [Event] = await self.clearPendingEvents()
                
                /// Execute the `action` in a detached task so that it avoids inheriting any potential cancelled state from the calling
                /// task, since we capture `self` weakly we don't need to worry about it outliving the owning object either
                Task.detached(priority: .userInitiated) { [weak self] in
                    await self?.action?(eventsToProcess)
                }
            } catch {
                // Task was cancelled so no need to do anything
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
}

public extension DebounceTaskManager {
    func signal(event: Event) {
        pendingEvents.append(event)
        scheduleSignal()
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
}
