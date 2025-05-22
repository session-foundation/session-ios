// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import Combine
import DifferenceKit
import SessionMessagingKit
import SessionUtilitiesKit

// MARK: - Log.Category

private extension Log.Category {
    static func cat(_ viewModel: Any) -> Log.Category {
        return .create("ObservableTableSource", customSuffix: "-\(type(of: viewModel))", defaultLevel: .warn)
    }
}

// MARK: - ObservableTableSource

public protocol ObservableTableSource: AnyObject, SectionedTableData {
    typealias TargetObservation = TableObservation<[SectionModel]>
    typealias TargetPublisher = AnyPublisher<[SectionModel], Error>
    
    var dependencies: Dependencies { get }
    var state: TableDataState<Section, TableItem> { get }
    var observableState: ObservableTableSourceState<Section, TableItem> { get }
    var observation: TargetObservation { get }
    
    // MARK: - Functions
    
    func didReturnFromBackground()
}

public enum ObservableTableSourceRefreshType {
    case databaseQuery
    case postDatabaseQuery
}

extension ObservableTableSource {
    public var pendingTableDataSubject: CurrentValueSubject<[SectionModel], Never> {
        self.observableState.pendingTableDataSubject
    }
    public var observation: TargetObservation {
        ObservationBuilder.subject(self.observableState.pendingTableDataSubject)
    }
    
    public var tableDataPublisher: TargetPublisher { self.observation.finalPublisher(self, using: dependencies) }
    
    public func didReturnFromBackground() {}
    public func forceRefresh(type: ObservableTableSourceRefreshType = .databaseQuery) {
        switch type {
            case .databaseQuery: self.observableState._forcedRequery.send(())
            case .postDatabaseQuery: self.observableState._forcedPostQueryRefresh.send(())
        }
    }
}

// MARK: - State Manager (ObservableTableSource)

public class ObservableTableSourceState<Section: SessionTableSection, TableItem: Hashable & Differentiable>: SectionedTableData {
    fileprivate let forcedRequery: AnyPublisher<Void, Never>
    fileprivate let forcedPostQueryRefresh: AnyPublisher<Void, Never>
    public let pendingTableDataSubject: CurrentValueSubject<[SectionModel], Never>
    
    // MARK: - Internal Variables
    
    fileprivate var hasEmittedInitialData: Bool
    fileprivate let _forcedRequery: PassthroughSubject<Void, Never> = PassthroughSubject()
    fileprivate let _forcedPostQueryRefresh: PassthroughSubject<Void, Never> = PassthroughSubject()
    
    // MARK: - Initialization
    
    init() {
        self.hasEmittedInitialData = false
        self.forcedRequery = _forcedRequery.shareReplay(0)
        self.forcedPostQueryRefresh = _forcedPostQueryRefresh.shareReplay(0)
        self.pendingTableDataSubject = CurrentValueSubject([])
    }
}

// MARK: - TableObservation

public struct TableObservation<T> {
    fileprivate let generatePublisher: (any ObservableTableSource, Dependencies) -> AnyPublisher<T, Error>
    fileprivate let generatePublisherWithChangeset: ((any ObservableTableSource, Dependencies) -> AnyPublisher<Any, Error>)?
    
    init(generatePublisher: @escaping (any ObservableTableSource, Dependencies) -> AnyPublisher<T, Error>) {
        self.generatePublisher = generatePublisher
        self.generatePublisherWithChangeset = nil
    }
    
    init(generatePublisherWithChangeset: @escaping (any ObservableTableSource, Dependencies) -> AnyPublisher<(T, StagedChangeset<T>), Error>) where T: Collection {
        self.generatePublisher = { _, _ in Fail(error: StorageError.invalidData).eraseToAnyPublisher() }
        self.generatePublisherWithChangeset = { source, dependencies in
            generatePublisherWithChangeset(source, dependencies).map { $0 as Any }.eraseToAnyPublisher()
        }
    }
    
    fileprivate func finalPublisher<S: ObservableTableSource>(
        _ source: S,
        using dependencies: Dependencies
    ) -> S.TargetPublisher {
        typealias TargetData = [S.SectionModel]
        
        switch (self, self.generatePublisherWithChangeset) {
            case (_, .some(let generatePublisherWithChangeset)):
                return generatePublisherWithChangeset(source, dependencies)
                    .tryMap { data -> TargetData in
                        guard let convertedData: TargetData = data as? TargetData else {
                            throw StorageError.invalidData
                        }
                        
                        return convertedData
                    }
                    /// Ignore outputs if the data hasn't changed from the current `tableData` value to avoid needlessly
                    /// reloading table data
                    .filter { [weak source] data in data != source?.state.tableData }
                    .eraseToAnyPublisher()
                
            case (let validObservation as S.TargetObservation, _):
                /// Doing `removeDuplicates` in case the conversion from the original data to `[SectionModel]`
                /// can result in duplicate output even with some different inputs
                return validObservation.generatePublisher(source, dependencies)
                    .removeDuplicates()
                    .mapToSessionTableViewData(for: source)
                    /// Ignore outputs if the data hasn't changed from the current `tableData` value to avoid needlessly
                    /// reloading table data
                    .filter { [weak source] data in data != source?.state.tableData }
                    .eraseToAnyPublisher()
                
            default: return Fail(error: StorageError.invalidData).eraseToAnyPublisher()
        }
    }
}

extension TableObservation: ExpressibleByArrayLiteral where T: Collection {
    public init(arrayLiteral elements: T.Element?...) {
        self.init(
            generatePublisher: { _, _ in
                guard let convertedElements: T = Array(elements.compactMap { $0 }) as? T else {
                    return Fail(error: StorageError.invalidData).eraseToAnyPublisher()
                }
                
                return Just(convertedElements)
                    .setFailureType(to: Error.self)
                    .eraseToAnyPublisher()
            }
        )
    }
}

// MARK: - ObservationBuilder

public enum ObservationBuilder {
    /// The `subject` will emit immediately when there is a subscriber and store the most recent value to be emitted whenever a new subscriber is
    /// added
    static func subject<T: Equatable>(_ subject: CurrentValueSubject<T, Error>) -> TableObservation<T> {
        return TableObservation { _, _ in
            return subject
                .removeDuplicates()
                .eraseToAnyPublisher()
        }
    }
    
    /// The `subject` will emit immediately when there is a subscriber and store the most recent value to be emitted whenever a new subscriber is
    /// added
    static func subject<T: Equatable>(_ subject: CurrentValueSubject<T, Never>) -> TableObservation<T> {
        return TableObservation { _, _ in
            return subject
                .removeDuplicates()
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
    }
    
    /// The `ValueObserveration` will trigger whenever any of the data fetched in the closure is updated, please see the following link for tips
    /// to help optimise performance https://github.com/groue/GRDB.swift#valueobservation-performance
    static func databaseObservation<S: ObservableTableSource, T: Equatable>(_ source: S, fetch: @escaping (Database) throws -> T) -> TableObservation<T> {
        /// **Note:** This observation will be triggered twice immediately (and be de-duped by the `removeDuplicates`)
        /// this is due to the behaviour of `ValueConcurrentObserver.asyncStartObservation` which triggers it's own
        /// fetch (after the ones in `ValueConcurrentObserver.asyncStart`/`ValueConcurrentObserver.syncStart`)
        /// just in case the database has changed between the two reads - unfortunately it doesn't look like there is a way to prevent this
        return TableObservation { viewModel, dependencies in
            let subject: CurrentValueSubject<T?, Error> = CurrentValueSubject(nil)
            var forcedRefreshCancellable: AnyCancellable?
            var observationCancellable: DatabaseCancellable?
            
            /// In order to force a `ValueObservation` to requery we need to resubscribe to it, as a result we create a
            /// `CurrentValueSubject` and in the `receiveSubscription` call we start the `ValueObservation` sending
            /// it's output into the subject
            ///
            /// **Note:** We need to use a `CurrentValueSubject` here because the `ValueObservation` could send it's
            /// first value _before_ the subscription is properly setup, by using a `CurrentValueSubject` the value will be stored
            /// and emitted once the subscription becomes valid
            return subject
                .compactMap { $0 }
                .handleEvents(
                    receiveSubscription: { subscription in
                        forcedRefreshCancellable = source.observableState.forcedRequery
                            .prepend(())
                            .sink(
                                receiveCompletion: { _ in },
                                receiveValue: { _ in
                                    /// Cancel any previous observation and create a brand new observation for this refresh
                                    ///
                                    /// **Note:** The `ValueObservation` **MUST** be started from the main thread
                                    observationCancellable?.cancel()
                                    observationCancellable = dependencies[singleton: .storage].start(
                                        ValueObservation
                                            .trackingConstantRegion(fetch)
                                            .removeDuplicates(),
                                        scheduling: dependencies[singleton: .scheduler],
                                        onError: { error in
                                            let log: String = [
                                                "Observation failed with error:",   // stringlint:ignore
                                                "\(error)"                          // stringlint:ignore
                                            ].joined(separator: " ")
                                            Log.error(.cat(viewModel), log)
                                            subject.send(completion: Subscribers.Completion.failure(error))
                                        },
                                        onChange: { subject.send($0) }
                                    )
                                }
                            )
                    },
                    receiveCancel: {
                        forcedRefreshCancellable?.cancel()
                        observationCancellable?.cancel()
                    }
                )
                .manualRefreshFrom(source.observableState.forcedPostQueryRefresh)
                .shareReplay(1) /// Share to prevent multiple subscribers resulting in multiple ValueObservations
                .eraseToAnyPublisher()
        }
    }
    
    static func databaseObservation<S: ObservableTableSource, T: Equatable>(_ source: S, fetch: @escaping (Database) throws -> [T]) -> TableObservation<[T]> {
        return TableObservation { viewModel, dependencies in
            let subject: CurrentValueSubject<[T]?, Error> = CurrentValueSubject(nil)
            var forcedRefreshCancellable: AnyCancellable?
            var observationCancellable: DatabaseCancellable?
            
            /// In order to force a `ValueObservation` to requery we need to resubscribe to it, as a result we create a
            /// `CurrentValueSubject` and in the `receiveSubscription` call we start the `ValueObservation` sending
            /// it's output into the subject
            ///
            /// **Note:** We need to use a `CurrentValueSubject` here because the `ValueObservation` could send it's
            /// first value _before_ the subscription is properly setup, by using a `CurrentValueSubject` the value will be stored
            /// and emitted once the subscription becomes valid
            return subject
                .compactMap { $0 }
                .handleEvents(
                    receiveSubscription: { subscription in
                        forcedRefreshCancellable = source.observableState.forcedRequery
                            .prepend(())
                            .sink(
                                receiveCompletion: { _ in },
                                receiveValue: { _ in
                                    /// Cancel any previous observation and create a brand new observation for this refresh
                                    ///
                                    /// **Note:** The `ValueObservation` **MUST** be started from the main thread
                                    observationCancellable?.cancel()
                                    observationCancellable = dependencies[singleton: .storage].start(
                                        ValueObservation
                                            .trackingConstantRegion(fetch)
                                            .removeDuplicates(),
                                        scheduling: dependencies[singleton: .scheduler],
                                        onError: { error in
                                            let log: String = [
                                                "Observation failed with error:",   // stringlint:ignore
                                                "\(error)"                          // stringlint:ignore
                                            ].joined(separator: " ")
                                            Log.error(.cat(viewModel), log)
                                            subject.send(completion: Subscribers.Completion.failure(error))
                                        },
                                        onChange: { subject.send($0) }
                                    )
                                }
                            )
                    },
                    receiveCancel: {
                        forcedRefreshCancellable?.cancel()
                        observationCancellable?.cancel()
                    }
                )
                .manualRefreshFrom(source.observableState.forcedPostQueryRefresh)
                .shareReplay(1) /// Share to prevent multiple subscribers resulting in multiple ValueObservations
                .eraseToAnyPublisher()
        }
    }
    
    static func refreshableData<S: ObservableTableSource, T: Equatable>(_ source: S, fetch: @escaping () -> T) -> TableObservation<T> {
        return TableObservation { viewModel, dependencies in
            source.observableState.forcedRequery
                .prepend(())
                .setFailureType(to: Error.self)
                .map { _ in fetch() }
                .manualRefreshFrom(source.observableState.forcedPostQueryRefresh)
        }
    }
    
    static func libSessionObservation<S: ObservableTableSource, T: Equatable>(
        _ source: S,
        debounceInterval: DispatchTimeInterval = .milliseconds(10),
        fetch: @escaping (KeyCollector) throws -> T
    ) -> TableObservation<T> {
        return TableObservation { viewModel, dependencies in
            let subject: CurrentValueSubject<T?, Error> = CurrentValueSubject(nil)
            let stream: AsyncThrowingStream<T, Error> = ObservationBuilder.libSessionObservation(
                dependencies,
                debounceInterval: debounceInterval,
                fetch: fetch
            )
            
            let mainObservationTask = Task {
                do {
                    for try await value in stream {
                        if Task.isCancelled { break }
                        subject.send(value)
                    }
                    
                    if !Task.isCancelled {
                        subject.send(completion: .finished)
                    }
                }
                catch is CancellationError { subject.send(completion: .finished) }
                catch { subject.send(completion: .failure(error)) }
            }
            
            return subject
                .compactMap { $0 }
                .handleEvents(
                    receiveCancel: {
                        tasks.forEach { $0.cancel() }
                    }
                )
                .manualRefreshFrom(source.observableState.forcedPostQueryRefresh)
                .shareReplay(1) /// Share to prevent multiple subscribers resulting in multiple ValueObservations
                .eraseToAnyPublisher()
        }
    }
    
    static func libSessionObservation<T: Equatable>(
        _ dependencies: Dependencies,
        debounceInterval: DispatchTimeInterval = .milliseconds(10),
        fetch: @escaping (KeyCollector) throws -> T
    ) -> AsyncThrowingStream<T, Error> {
        return AsyncThrowingStream<T, Error> { continuation in
            let debouncer: DebounceTaskManager<T> = DebounceTaskManager(debounceInterval: debounceInterval)
            let taskManager: MultiTaskManager<Void> = MultiTaskManager()
            
            let mainObservationTask = Task {
                let initialInfo: (initialValue: T, streams: [AsyncStream<Any?>])
                
                do {
                    /// Retrieve the initial value and they keys to observe
                    initialInfo = try dependencies.mutate(cache: .libSession) { cache in
                        let collector: KeyCollector = KeyCollector(store: cache)
                        let value: T = try fetch(collector)
                        
                        return (value, collector.collectedKeys.map { cache.observe($0) })
                    }
                    guard !Task.isCancelled else { throw CancellationError() }
                    continuation.yield(initialInfo.initialValue)
                    
                }
                catch {
                    continuation.finish(throwing: error)
                    await debouncer.reset()
                    await taskManager.cancelAll()
                    return
                }
                
                /// After debouncing we want to re-fetch the data
                await debouncer.setAction { continuation in
                    let newValue: T = try dependencies.mutate(cache: .libSession) { cache in
                        try fetch(KeyCollector(store: cache))
                    }
                    
                    guard !Task.isCancelled else { throw CancellationError() }
                    continuation.yield(newValue)
                }
                
                /// Start observing the streams for updates
                for stream in initialInfo.streams {
                    guard !Task.isCancelled else { break }
                    
                    let keyTask = Task {
                        for await _ in stream {
                            guard !Task.isCancelled else { break }
                            await debouncer.signal(continuation: continuation)
                        }
                    }
                    await taskManager.add(keyTask)
                }
            }

            continuation.onTermination = { @Sendable _ in
                mainObservationTask.cancel()
                
                Task {
                    await debouncer.reset()
                    await taskManager.cancelAll()
                }
            }
        }
    }
}

// MARK: - Convenience Transforms

public extension TableObservation {
    func map<R>(transform: @escaping (T) -> R) -> TableObservation<R> {
        return TableObservation<R> { viewModel, dependencies in
            self.generatePublisher(viewModel, dependencies).map(transform).eraseToAnyPublisher()
        }
    }
    
    func compactMap<R>(transform: @escaping (T) -> R?) -> TableObservation<R> {
        return TableObservation<R> { viewModel, dependencies in
            self.generatePublisher(viewModel, dependencies).compactMap(transform).eraseToAnyPublisher()
        }
    }
    
    func mapWithPrevious<R>(transform: @escaping (T?, T) -> R) -> TableObservation<R> {
        return TableObservation<R> { viewModel, dependencies in
            self.generatePublisher(viewModel, dependencies)
                .withPrevious()
                .map(transform)
                .eraseToAnyPublisher()
        }
    }
    
    func compactMapWithPrevious<R>(transform: @escaping (T?, T) -> R?) -> TableObservation<R> {
        return TableObservation<R> { viewModel, dependencies in
            self.generatePublisher(viewModel, dependencies)
                .withPrevious()
                .compactMap(transform)
                .eraseToAnyPublisher()
        }
    }
}

public extension Array {
    func mapToSessionTableViewData<S: ObservableTableSource>(
        for source: S?
    ) -> [ArraySection<S.Section, SessionCell.Info<S.TableItem>>] where Element == ArraySection<S.Section, SessionCell.Info<S.TableItem>> {
        // Update the data to include the proper position for each element
        return self.map { section in
            ArraySection(
                model: section.model,
                elements: section.elements.enumerated().map { index, element in
                    element.updatedPosition(for: index, count: section.elements.count)
                }
            )
        }
    }
}

public extension Publisher {
    func mapToSessionTableViewData<S: ObservableTableSource>(
        for source: S
    ) -> AnyPublisher<Output, Failure> where Output == [ArraySection<S.Section, SessionCell.Info<S.TableItem>>] {
        return self
            .map { [weak source] updatedData -> Output in
                updatedData.mapToSessionTableViewData(for: source)
            }
            .eraseToAnyPublisher()
    }
}

// MARK: - KeyCollector

public class KeyCollector: ValueFetcher {
    private let store: ValueFetcher
    private(set) var collectedKeys: Set<LibSession.ObservableKey> = []
    
    public var userSessionId: SessionId { store.userSessionId }
    
    init(store: ValueFetcher) {
        self.store = store
    }
    
    func register(_ key: LibSession.ObservableKey) {
        collectedKeys.insert(key)
    }
    
    func register(_ key: Setting.BoolKey) {
        collectedKeys.insert(.setting(key))
    }
    
    func register(_ key: Setting.EnumKey) {
        collectedKeys.insert(.setting(key))
    }
    
    // MARK: - ValueFetcher
    
    public func has(_ key: Setting.BoolKey) -> Bool {
        collectedKeys.insert(.setting(key))
        return store.has(key)
    }
    
    public func has(_ key: Setting.EnumKey) -> Bool {
        collectedKeys.insert(.setting(key))
        return store.has(key)
    }
    
    public func get(_ key: Setting.BoolKey) -> Bool {
        collectedKeys.insert(.setting(key))
        return store.get(key)
    }
    
    public func get<T: RawRepresentable>(_ key: Setting.EnumKey) -> T? where T.RawValue == Int {
        collectedKeys.insert(.setting(key))
        return store.get(key)
    }
    
    public func profile(
        contactId: String,
        threadId: String?,
        threadVariant: SessionThread.Variant?,
        visibleMessage: VisibleMessage?
    ) -> Profile? {
        collectedKeys.insert(.profile(contactId))
        return store.profile(
            contactId: contactId,
            threadId: threadId,
            threadVariant: threadVariant,
            visibleMessage: visibleMessage
        )
    }
}
