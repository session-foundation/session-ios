// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Combine

public protocol CombineCompatible {}

public extension Publisher {
    /// Provides a subject that shares a single subscription to the upstream publisher and replays at most
    /// `bufferSize` items emitted by that publisher
    /// - Parameter bufferSize: limits the number of items that can be replayed
    func shareReplay(_ bufferSize: Int) -> AnyPublisher<Output, Failure> {
        return multicast(subject: ReplaySubject(bufferSize))
            .autoconnect()
            .eraseToAnyPublisher()
    }
    
    func sink(into subject: PassthroughSubject<Output, Failure>, includeCompletions: Bool = false) -> AnyCancellable {
        return sink(
            receiveCompletion: { completion in
                guard includeCompletions else { return }
                
                subject.send(completion: completion)
            },
            receiveValue: { value in subject.send(value) }
        )
    }
    
    func tryFlatMap<T, P>(
        maxPublishers: Subscribers.Demand = .unlimited,
        _ transform: @escaping (Self.Output) throws -> P
    ) -> AnyPublisher<T, Error> where T == P.Output, P : Publisher, P.Failure == Error {
        return self
            .mapError { $0 }
            .flatMap(maxPublishers: maxPublishers) { output -> AnyPublisher<P.Output, Error> in
                do {
                    return try transform(output)
                        .eraseToAnyPublisher()
                }
                catch {
                    return Fail<P.Output, Error>(error: error)
                        .eraseToAnyPublisher()
                }
            }
            .eraseToAnyPublisher()
    }
    
    func subscribe<S>(
        on scheduler: S,
        options: S.SchedulerOptions? = nil,
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<Output, Failure> where S: Scheduler {
        guard !dependencies.forceSynchronous else { return self.eraseToAnyPublisher() }
        
        return self.subscribe(on: scheduler, options: options)
            .eraseToAnyPublisher()
    }
    
    func receive<S>(
        on scheduler: S,
        options: S.SchedulerOptions? = nil,
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<Output, Failure> where S: Scheduler {
        guard !dependencies.forceSynchronous else { return self.eraseToAnyPublisher() }
        
        return self.receive(on: scheduler, options: options)
            .eraseToAnyPublisher()
    }
}

// MARK: - Convenience

public extension Publisher {
    func sink(into subject: PassthroughSubject<Output, Failure>?, includeCompletions: Bool = false) -> AnyCancellable {
        guard let targetSubject: PassthroughSubject<Output, Failure> = subject else { return AnyCancellable {} }
        
        return sink(into: targetSubject, includeCompletions: includeCompletions)
    }
    
    /// Automatically retains the subscription until it emits a 'completion' event
    func sinkUntilComplete(
        receiveCompletion: ((Subscribers.Completion<Failure>) -> Void)? = nil,
        receiveValue: ((Output) -> Void)? = nil
    ) {
        var retainCycle: Cancellable? = nil
        retainCycle = self
            .sink(
                receiveCompletion: { result in
                    receiveCompletion?(result)
                    
                    // Redundant but without reading 'retainCycle' it will warn that the variable
                    // isn't used
                    if retainCycle != nil { retainCycle = nil }
                },
                receiveValue: (receiveValue ?? { _ in })
            )
    }
}

public extension AnyPublisher {
    /// Converts the publisher to output a Result instead of throwing an error, can be used to ensure a subscription never
    /// closes due to a failure
    func asResult() -> AnyPublisher<Result<Output, Failure>, Never> {
        self
            .map { Result<Output, Failure>.success($0) }
            .catch { Just(Result<Output, Failure>.failure($0)).eraseToAnyPublisher() }
            .eraseToAnyPublisher()
    }
}

// MARK: - Data Decoding

public extension Publisher where Output == Data, Failure == Error {
    func decoded<R: Decodable>(
        as type: R.Type,
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<R, Failure> {
        self
            .tryMap { data -> R in try data.decoded(as: type, using: dependencies) }
            .eraseToAnyPublisher()
    }
}

public extension Publisher where Output == (ResponseInfoType, Data?), Failure == Error {
    func decoded<R: Decodable>(
        as type: R.Type,
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<(ResponseInfoType, R), Error> {
        self
            .tryMap { responseInfo, maybeData -> (ResponseInfoType, R) in
                guard let data: Data = maybeData else { throw HTTPError.parsingFailed }
                
                return (responseInfo, try data.decoded(as: type, using: dependencies))
            }
            .eraseToAnyPublisher()
    }
}
