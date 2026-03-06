// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

// MARK: - Singleton

public extension Singleton {
    static let fileHandleFactory: SingletonConfig<FileHandleFactoryType> = Dependencies.create(
        identifier: "fileHandleFactory",
        createInstance: { _, _ in SessionFileHandleFactory() }
    )
}

// MARK: - FileHandleFactoryType

public protocol FileHandleFactoryType {
    func create(forWritingTo url: URL) throws -> FileHandleType
    func create(forWritingAtPath path: String) -> FileHandleType?
    func create(forReadingFrom url: URL) throws -> FileHandleType
    func create(forReadingAtPath path: String) -> FileHandleType?
}

// MARK: - SessionFileHandleFactory

public final class SessionFileHandleFactory: FileHandleFactoryType {
    public func create(forWritingTo url: URL) throws -> FileHandleType {
        return try FileHandle(forWritingTo: url)
    }
    
    public func create(forWritingAtPath path: String) -> FileHandleType? {
        return FileHandle(forWritingAtPath: path)
    }
    
    public func create(forReadingFrom url: URL) throws -> FileHandleType {
        return try FileHandle(forReadingFrom: url)
    }
    
    public func create(forReadingAtPath path: String) -> FileHandleType? {
        return FileHandle(forReadingAtPath: path)
    }
}

// MARK: - FileHandleType

public protocol FileHandleType {
    func readToEnd() throws -> Data?
    func read(upToCount count: Int) throws -> Data?
    func offset() throws -> UInt64
    @discardableResult func seekToEnd() throws -> UInt64
    func write<T>(contentsOf data: T) throws where T : DataProtocol
    func close() throws
}

extension FileHandle: FileHandleType {}
