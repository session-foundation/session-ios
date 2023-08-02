// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Combine
import GRDB

@testable import SessionUtilitiesKit

class SynchronousStorage: Storage {
    @discardableResult override func write<T>(
        fileName: String = #file,
        functionName: String = #function,
        lineNumber: Int = #line,
        using dependencies: Dependencies = Dependencies(),
        updates: @escaping (Database) throws -> T?
    ) -> T? {
        guard isValid, let dbWriter: DatabaseWriter = testDbWriter else { return nil }
        
        // If 'forceSynchronous' is true then it's likely that we will access the database in
        // a reentrant way, the 'unsafeReentrant...' functions allow us to interact with the
        // database without worrying about reentrant access during tests because we can be
        // confident that the tests are running on the correct thread
        guard !dependencies.forceSynchronous else {
            return try? dbWriter.unsafeReentrantWrite(updates)
        }
        
        return super.write(
            fileName: fileName,
            functionName: functionName,
            lineNumber: lineNumber,
            using: dependencies,
            updates: updates
        )
    }
    
    @discardableResult override func read<T>(
        using dependencies: Dependencies = Dependencies(),
        _ value: (Database) throws -> T?
    ) -> T? {
        guard isValid, let dbWriter: DatabaseWriter = testDbWriter else { return nil }
        
        // If 'forceSynchronous' is true then it's likely that we will access the database in
        // a reentrant way, the 'unsafeReentrant...' functions allow us to interact with the
        // database without worrying about reentrant access during tests because we can be
        // confident that the tests are running on the correct thread
        guard !dependencies.forceSynchronous else {
            return try? dbWriter.unsafeReentrantRead(value)
        }
        
        return super.read(using: dependencies, value)
    }
    
    // MARK: - Async Methods
    
    override func readPublisher<T>(
        using dependencies: Dependencies = Dependencies(),
        value: @escaping (Database) throws -> T
    ) -> AnyPublisher<T, Error> {
        guard let result: T = self.read(using: dependencies, value) else {
            return Fail(error: StorageError.generic)
                .eraseToAnyPublisher()
        }
        
        return Just(result)
            .setFailureType(to: Error.self)
            .eraseToAnyPublisher()
    }
    
    override func writeAsync<T>(
        fileName: String = #file,
        functionName: String = #function,
        lineNumber: Int = #line,
        using dependencies: Dependencies = Dependencies(),
        updates: @escaping (Database) throws -> T,
        completion: @escaping (Database, Result<T, Error>) throws -> Void
    ) {
        do {
            let result: T = try write(using: dependencies, updates: updates) ?? { throw StorageError.failedToSave }()
            write { db in try completion(db, Result.success(result)) }
        }
        catch {
            write { db in try completion(db, Result.failure(error)) }
        }
    }
    
    override func writePublisher<T>(
        fileName: String = #file,
        functionName: String = #function,
        lineNumber: Int = #line,
        using dependencies: Dependencies = Dependencies(),
        updates: @escaping (Database) throws -> T
    ) -> AnyPublisher<T, Error> {
        guard let result: T = super.write(fileName: fileName, functionName: functionName, lineNumber: lineNumber, using: dependencies, updates: updates) else {
            return Fail(error: StorageError.generic)
                .eraseToAnyPublisher()
        }
        
        return Just(result)
            .setFailureType(to: Error.self)
            .eraseToAnyPublisher()
    }
}
