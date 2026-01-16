// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

class MockFileManager: Mock<FileManagerType>, FileManagerType {
    var temporaryDirectory: String { mock() }
    var documentsDirectoryPath: String { mock() }
    var appSharedDataDirectoryPath: String { mock() }
    
    func clearOldTemporaryDirectories() { mockNoReturn() }
    
    func ensureDirectoryExists(at path: String, fileProtectionType: FileProtectionType) throws {
        try mockThrowingNoReturn(args: [path, fileProtectionType])
    }
    
    
    func protectFileOrFolder(at path: String, fileProtectionType: FileProtectionType) throws {
        try mockThrowingNoReturn(args: [path, fileProtectionType])
    }
    
    func fileSize(of path: String) -> UInt64? {
        return mock(args: [path])
    }
    
    func isLocatedInTemporaryDirectory(_ path: String) -> Bool {
        return mock(args: [path])
    }
    
    func temporaryFilePath(fileExtension: String?) -> String {
        return mock(args: [fileExtension])
    }
    
    func write(data: Data, toTemporaryFileWithExtension fileExtension: String?) throws -> String {
        return try mockThrowing(args: [data, fileExtension])
    }
    
    func write(data: Data, toPath path: String) throws {
        try mockThrowingNoReturn(args: [data, path])
    }
    
    // MARK: - Forwarded NSFileManager
    
    var currentDirectoryPath: String { mock() }
    
    func urls(for directory: FileManager.SearchPathDirectory, in domains: FileManager.SearchPathDomainMask) -> [URL] {
        return mock(args: [directory, domains])
    }
    
    func enumerator(
        at url: URL,
        includingPropertiesForKeys: [URLResourceKey]?,
        options: FileManager.DirectoryEnumerationOptions,
        errorHandler: ((URL, Error) -> Bool)?
    ) -> FileManager.DirectoryEnumerator? {
        return mock(args: [url, includingPropertiesForKeys, options, errorHandler])
    }
    
    func fileExists(atPath: String) -> Bool { return mock(args: [atPath]) }
    func fileExists(atPath: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        return mock(args: [atPath, isDirectory])
    }
    
    func contents(atPath: String) throws -> Data { return try mockThrowing(args: [atPath]) }
    func contentsOfDirectory(at url: URL) throws -> [URL] { return try mockThrowing(args: [url]) }
    func contentsOfDirectory(atPath path: String) throws -> [String] { return try mockThrowing(args: [path]) }
    func isDirectoryEmpty(at url: URL) -> Bool { return mock(args: [url]) }
    func isDirectoryEmpty(atPath path: String) -> Bool { return mock(args: [path]) }
    
    func createFile(atPath: String, contents: Data?, attributes: [FileAttributeKey : Any]?) -> Bool {
        return mock(args: [atPath, contents, attributes])
    }
    
    func createDirectory(atPath: String, withIntermediateDirectories: Bool, attributes: [FileAttributeKey: Any]?) throws {
        try mockThrowingNoReturn(args: [atPath, withIntermediateDirectories, attributes])
    }
    
    func createDirectory(at url: URL, withIntermediateDirectories: Bool, attributes: [FileAttributeKey: Any]?) throws {
        try mockThrowingNoReturn(args: [url, withIntermediateDirectories, attributes])
    }
    
    func copyItem(atPath: String, toPath: String) throws { return try mockThrowing(args: [atPath, toPath]) }
    func copyItem(at fromUrl: URL, to toUrl: URL) throws { return try mockThrowing(args: [fromUrl, toUrl]) }
    func moveItem(atPath: String, toPath: String) throws { return try mockThrowing(args: [atPath, toPath]) }
    func moveItem(at fromUrl: URL, to toUrl: URL) throws { return try mockThrowing(args: [fromUrl, toUrl]) }
    func replaceItem(
        atPath originalItemPath: String,
        withItemAtPath newItemPath: String,
        backupItemName: String?,
        options: FileManager.ItemReplacementOptions
    ) throws -> String? {
        return try mockThrowing(args: [originalItemPath, newItemPath, backupItemName, options])
    }
    func replaceItemAt(
        _ originalItemURL: URL,
        withItemAt newItemURL: URL,
        backupItemName: String?,
        options: FileManager.ItemReplacementOptions
    ) throws -> URL? {
        return try mockThrowing(args: [originalItemURL, newItemURL, backupItemName, options])
    }
    func removeItem(atPath: String) throws { return try mockThrowing(args: [atPath]) }
    
    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        return try mockThrowing(args: [path])
    }
    
    func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        try mockThrowingNoReturn(args: [attributes, path])
    }
}

// MARK: - Convenience

extension Mock where T == FileManagerType {
    func defaultInitialSetup() {
        self.when { $0.appSharedDataDirectoryPath }.thenReturn("/test")
        self.when { try $0.ensureDirectoryExists(at: .any, fileProtectionType: .any) }.thenReturn(())
        self.when { try $0.protectFileOrFolder(at: .any, fileProtectionType: .any) }.thenReturn(())
        self.when { $0.fileExists(atPath: .any) }.thenReturn(false)
        self.when { $0.fileExists(atPath: .any, isDirectory: .any) }.thenReturn(false)
        self.when { $0.fileSize(of: .any) }.thenReturn(1024)
        self.when { $0.isLocatedInTemporaryDirectory(.any) }.thenReturn(false)
        self.when { $0.temporaryFilePath(fileExtension: .any) }.thenReturn("tmpFile")
        self.when { $0.createFile(atPath: .any, contents: .any, attributes: .any) }.thenReturn(true)
        self.when { try $0.write(dataToTemporaryFile: .any) }.thenReturn("tmpFile")
        self.when { try $0.write(data: .any, toPath: .any) }.thenReturn(())
        self.when { try $0.setAttributes(.any, ofItemAtPath: .any) }.thenReturn(())
        self.when { try $0.copyItem(atPath: .any, toPath: .any) }.thenReturn(())
        self.when { try $0.moveItem(atPath: .any, toPath: .any) }.thenReturn(())
        self.when {
            _ = try $0.replaceItem(
                atPath: .any,
                withItemAtPath: .any,
                backupItemName: .any,
                options: .any
            )
        }.thenReturn(nil)
        self.when {
            _ = try $0.replaceItemAt(
                .any,
                withItemAt: .any,
                backupItemName: .any,
                options: .any
            )
        }.thenReturn(nil)
        self.when { try $0.removeItem(atPath: .any) }.thenReturn(())
        self.when { try $0.contents(atPath: .any) }.thenReturn(Data([1, 2, 3]))
        self.when { try $0.contentsOfDirectory(at: .any) }.thenReturn([])
        self.when { try $0.contentsOfDirectory(atPath: .any) }.thenReturn([])
        self.when {
            try $0.createDirectory(
                atPath: .any,
                withIntermediateDirectories: .any,
                attributes: .any
            )
        }.thenReturn(())
        self.when { $0.isDirectoryEmpty(atPath: .any) }.thenReturn(true)
    }
}
