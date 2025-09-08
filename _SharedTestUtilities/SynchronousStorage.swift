// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Combine
import GRDB
import TestUtilities

@testable import SessionUtilitiesKit

class SynchronousStorage: Storage {
    public let dependencies: Dependencies
    
    public override init(customWriter: DatabaseWriter? = nil, using dependencies: Dependencies) {
        self.dependencies = dependencies
        
        super.init(customWriter: customWriter, using: dependencies)
    }
    
    // MARK: - Overwritten Functions
    
    @discardableResult override func write<T>(
        fileName: String = #fileID,
        functionName: String = #function,
        lineNumber: Int = #line,
        updates: @escaping (ObservingDatabase) throws -> T?
    ) -> T? {
        guard isValid, let dbWriter: DatabaseWriter = testDbWriter else { return nil }
        
        // If 'forceSynchronous' is true then it's likely that we will access the database in
        // a reentrant way, the 'unsafeReentrant...' functions allow us to interact with the
        // database without worrying about reentrant access during tests because we can be
        // confident that the tests are running on the correct thread
        guard !dependencies.forceSynchronous else {
            var result: T?
            var events: [ObservedEvent] = []
            var actions: [String: () -> Void] = [:]
            
            do {
                try dbWriter.unsafeReentrantWrite { [dependencies] db in
                    let observingDatabase: ObservingDatabase = ObservingDatabase.create(db, using: dependencies)
                    result = try ObservationContext.$observingDb.withValue(observingDatabase) {
                        try updates(observingDatabase)
                    }
                    
                    events = observingDatabase.events
                    actions = observingDatabase.postCommitActions
                }
                
                /// Forcibly trigger `ObservableEvent` and `postCommitActions` when forcing synchronous logic
                dependencies.notifyAsync(events: events)
                
                actions.values.forEach { $0() }
            }
            catch {}
            
            return result
        }
        
        return super.write(
            fileName: fileName,
            functionName: functionName,
            lineNumber: lineNumber,
            updates: updates
        )
    }
    
    @discardableResult override func read<T>(
        fileName: String = #fileID,
        functionName: String = #function,
        lineNumber: Int = #line,
        _ value: @escaping (ObservingDatabase) throws -> T?
    ) -> T? {
        guard isValid, let dbWriter: DatabaseWriter = testDbWriter else { return nil }
        
        // If 'forceSynchronous' is true then it's likely that we will access the database in
        // a reentrant way, the 'unsafeReentrant...' functions allow us to interact with the
        // database without worrying about reentrant access during tests because we can be
        // confident that the tests are running on the correct thread
        guard !dependencies.forceSynchronous else {
            var result: T?
            var events: [ObservedEvent] = []
            var actions: [String: () -> Void] = [:]
            
            do {
                try dbWriter.unsafeReentrantRead { [dependencies] db in
                    let observingDatabase: ObservingDatabase = ObservingDatabase.create(db, using: dependencies)
                    result = try ObservationContext.$observingDb.withValue(observingDatabase) {
                        try value(observingDatabase)
                    }
                    
                    events = observingDatabase.events
                    actions = observingDatabase.postCommitActions
                }
                
                /// Forcibly trigger `ObservableEvent` and `postCommitActions` when forcing synchronous logic
                dependencies.notifyAsync(events: events)
                
                actions.values.forEach { $0() }
            }
            catch {}
            
            return result
        }
        
        return super.read(
            fileName: fileName,
            functionName: functionName,
            lineNumber: lineNumber,
            value
        )
    }
    
    // MARK: - Async Methods
    
    override func readPublisher<T>(
        fileName: String = #fileID,
        functionName: String = #function,
        lineNumber: Int = #line,
        value: @escaping (ObservingDatabase) throws -> T
    ) -> AnyPublisher<T, Error> {
        guard isValid, let dbWriter: DatabaseWriter = testDbWriter else {
            return Fail(error: StorageError.generic)
                .eraseToAnyPublisher()
        }
        
        // If 'forceSynchronous' is true then it's likely that we will access the database in
        // a reentrant way, the 'unsafeReentrant...' functions allow us to interact with the
        // database without worrying about reentrant access during tests because we can be
        // confident that the tests are running on the correct thread
        guard !dependencies.forceSynchronous else {
            var events: [ObservedEvent] = []
            var actions: [String: () -> Void] = [:]
            
            return Just(())
                .setFailureType(to: Error.self)
                .tryMap { [dependencies] _ in
                    try dbWriter.unsafeReentrantRead { [dependencies] db in
                        let observingDatabase: ObservingDatabase = ObservingDatabase.create(db, using: dependencies)
                        let result: T = try ObservationContext.$observingDb.withValue(observingDatabase) {
                            try value(observingDatabase)
                        }
                        
                        events = observingDatabase.events
                        actions = observingDatabase.postCommitActions
                        
                        return result
                    }
                }
                .handleEvents(
                    receiveCompletion: { [dependencies] result in
                        /// Forcibly trigger `ObservableEvent` and `postCommitActions` when forcing synchronous logic
                        dependencies.notifyAsync(events: events)
                        
                        actions.values.forEach { $0() }
                    }
                )
                .eraseToAnyPublisher()
        }
        
        return super.readPublisher(fileName: fileName, functionName: functionName, lineNumber: lineNumber, value: value)
    }
    
    override func writeAsync<T>(
        fileName: String = #fileID,
        functionName: String = #function,
        lineNumber: Int = #line,
        updates: @escaping (ObservingDatabase) throws -> T,
        completion: @escaping (Result<T, Error>) -> Void
    ) {
        do {
            let result: T = try write(updates: updates) ?? { throw StorageError.failedToSave }()
            completion(Result.success(result))
        }
        catch {
            completion(Result.failure(error))
        }
    }
    
    override func writePublisher<T>(
        fileName: String = #fileID,
        functionName: String = #function,
        lineNumber: Int = #line,
        updates: @escaping (ObservingDatabase) throws -> T
    ) -> AnyPublisher<T, Error> {
        guard isValid, let dbWriter: DatabaseWriter = testDbWriter else {
            return Fail(error: StorageError.generic)
                .eraseToAnyPublisher()
        }
        
        // If 'forceSynchronous' is true then it's likely that we will access the database in
        // a reentrant way, the 'unsafeReentrant...' functions allow us to interact with the
        // database without worrying about reentrant access during tests because we can be
        // confident that the tests are running on the correct thread
        guard !dependencies.forceSynchronous else {
            var events: [ObservedEvent] = []
            var actions: [String: () -> Void] = [:]
            
            return Just(())
                .setFailureType(to: Error.self)
                .tryMap { [dependencies] _ in
                    try dbWriter.unsafeReentrantWrite { [dependencies] db in
                        let observingDatabase: ObservingDatabase = ObservingDatabase.create(db, using: dependencies)
                        let result: T = try ObservationContext.$observingDb.withValue(observingDatabase) {
                            try updates(observingDatabase)
                        }
                        
                        events = observingDatabase.events
                        actions = observingDatabase.postCommitActions
                        
                        return result
                    }
                }
                .handleEvents(
                    receiveCompletion: { [dependencies] result in
                        /// Forcibly trigger `ObservableEvent` and `postCommitActions` when forcing synchronous logic
                        dependencies.notifyAsync(events: events)
                        
                        actions.values.forEach { $0() }
                    }
                )
                .eraseToAnyPublisher()
        }
        
        return super.writePublisher(fileName: fileName, functionName: functionName, lineNumber: lineNumber, updates: updates)
    }
}
