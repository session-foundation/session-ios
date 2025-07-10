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

            do {
                try await Task.sleep(for: self.debounceInterval)
                guard !Task.isCancelled else { return }
                
                let eventsToProcess: [Event] = await self.clearPendingEvents()
                await self.action?(eventsToProcess)
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
