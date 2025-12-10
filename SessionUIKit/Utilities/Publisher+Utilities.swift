// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Combine

public extension Publisher {
    /// Converts the publisher to output a Result instead of throwing an error, can be used to ensure a subscription never
    /// closes due to a failure
    func asResult() -> AnyPublisher<Result<Output, Failure>, Never> {
        self
            .map { Result<Output, Failure>.success($0) }
            .catch { Just(Result<Output, Failure>.failure($0)).eraseToAnyPublisher() }
            .eraseToAnyPublisher()
    }
    
    /// Provides a subject that shares a single subscription to the upstream publisher and replays at most
    /// `bufferSize` items emitted by that publisher
    /// - Parameter bufferSize: limits the number of items that can be replayed
    func shareReplay(_ bufferSize: Int) -> AnyPublisher<Output, Failure> {
        return multicast(subject: ReplaySubject(bufferSize))
            .autoconnect()
            .eraseToAnyPublisher()
    }
}

/// A subject that stores the last `bufferSize` emissions and emits them for every new subscriber
///
/// Note: This implementation was found here: https://github.com/sgl0v/OnSwiftWings
public final class ReplaySubject<Output, Failure: Error>: Subject {
    private var buffer: [Output] = [Output]()
    private let bufferSize: Int
    private let lock: NSRecursiveLock = NSRecursiveLock()
    private var completion: Subscribers.Completion<Failure>?
    private var subscriptions: [ReplaySubjectSubscription<Output, Failure>] = []
    
    // MARK: - Initialization

    init(_ bufferSize: Int = 0) {
        self.bufferSize = bufferSize
    }
    
    // MARK: - Subject Methods
    
    /// Sends a value to the subscriber
    public func send(_ value: Output) {
        lock.lock(); defer { lock.unlock() }
        
        buffer.append(value)
        buffer = buffer.suffix(bufferSize)
        subscriptions.forEach { $0.receive(value) }
    }
    
    /// Sends a completion signal to the subscriber
    public func send(completion: Subscribers.Completion<Failure>) {
        lock.lock(); defer { lock.unlock() }
        
        self.completion = completion
        subscriptions.forEach { $0.receive(completion: completion) }
    }
    
    /// Provides this Subject an opportunity to establish demand for any new upstream subscriptions
    public func send(subscription: Subscription) {
        lock.lock(); defer { lock.unlock() }
        
        subscription.request(.unlimited)
    }
    
    /// This function is called to attach the specified `Subscriber` to the`Publisher
    public func receive<S>(subscriber: S) where S: Subscriber, Failure == S.Failure, Output == S.Input {
        lock.lock(); defer { lock.unlock() }
        
        let subscription = ReplaySubjectSubscription<Output, Failure>(downstream: AnySubscriber(subscriber))
        subscriber.receive(subscription: subscription)
        subscriptions.append(subscription)
        subscription.replay(buffer, completion: completion)
    }
}

// MARK: -

public final class ReplaySubjectSubscription<Output, Failure: Error>: Subscription {
    private let downstream: AnySubscriber<Output, Failure>
    private var isCompleted = false
    private var demand: Subscribers.Demand = .none

    public init(downstream: AnySubscriber<Output, Failure>) {
        self.downstream = downstream
    }

    // Tells a publisher that it may send more values to the subscriber.
    public func request(_ newDemand: Subscribers.Demand) {
        demand += newDemand
    }

    public func cancel() {
        guard !isCompleted else { return }
        isCompleted = true
    }

    public func receive(_ value: Output) {
        guard !isCompleted, demand > 0 else { return }

        demand += downstream.receive(value)
        demand -= 1
    }

    public func receive(completion: Subscribers.Completion<Failure>) {
        guard !isCompleted else { return }
        isCompleted = true
        downstream.receive(completion: completion)
    }

    public func replay(_ values: [Output], completion: Subscribers.Completion<Failure>?) {
        guard !isCompleted else { return }
        values.forEach { value in receive(value) }
        if let completion = completion { receive(completion: completion) }
    }
}

