// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import UIKit.UIImage
import SessionUtilitiesKit
import TestUtilities

final class MockFileManager: FileManagerType, Mockable {
    public let handler: MockHandler<FileManagerType>
    
    required init(handler: MockHandler<FileManagerType>) {
        self.handler = handler
    }
    
    required init(handlerForBuilder: any MockFunctionHandler) {
        self.handler = MockHandler(forwardingHandler: handlerForBuilder)
    }
    
    var temporaryDirectory: String { handler.mock() }
    var documentsDirectoryPath: String { handler.mock() }
    var appSharedDataDirectoryPath: String { handler.mock() }
    var temporaryDirectoryAccessibleAfterFirstAuth: String { handler.mock() }
    
    func clearOldTemporaryDirectories() { handler.mockNoReturn() }
    
    func ensureDirectoryExists(at path: String, fileProtectionType: FileProtectionType) throws {
        try handler.mockThrowingNoReturn(args: [path, fileProtectionType])
    }
    
    
    func protectFileOrFolder(at path: String, fileProtectionType: FileProtectionType) throws {
        try handler.mockThrowingNoReturn(args: [path, fileProtectionType])
    }
    
    func fileSize(of path: String) -> UInt64? {
        return handler.mock(args: [path])
    }
    
    func isLocatedInTemporaryDirectory(_ path: String) -> Bool {
        return handler.mock(args: [path])
    }
    
    func temporaryFilePath(fileExtension: String?) -> String {
        return handler.mock(args: [fileExtension])
    }
    
    func write(data: Data, toTemporaryFileWithExtension fileExtension: String?) throws -> String {
        return try handler.mockThrowing(args: [data, fileExtension])
    }
    
    func write(data: Data, toPath path: String) throws {
        try handler.mockThrowingNoReturn(args: [data, path])
    }
    
    func write(data: Data, toTemporaryFileWithExtension fileExtension: String?) throws -> String? {
        return try handler.mockThrowing(args: [data, fileExtension])
    }
    
    // MARK: - Forwarded NSFileManager
    
    var currentDirectoryPath: String { handler.mock() }
    
    func urls(for directory: FileManager.SearchPathDirectory, in domains: FileManager.SearchPathDomainMask) -> [URL] {
        return handler.mock(args: [directory, domains])
    }
    
    func enumerator(
        at url: URL,
        includingPropertiesForKeys: [URLResourceKey]?,
        options: FileManager.DirectoryEnumerationOptions,
        errorHandler: ((URL, Error) -> Bool)?
    ) -> FileManager.DirectoryEnumerator? {
        return handler.mock(args: [url, includingPropertiesForKeys, options, errorHandler])
    }
    
    func fileExists(atPath: String) -> Bool { return handler.mock(args: [atPath]) }
    func fileExists(atPath: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        return handler.mock(args: [atPath, isDirectory])
    }
    
    func contents(atPath: String) throws -> Data { return try handler.mockThrowing(args: [atPath]) }
    func imageContents(atPath: String) -> UIImage? { return handler.mock(args: [atPath]) }
    func contentsOfDirectory(at url: URL) throws -> [URL] { return try handler.mockThrowing(args: [url]) }
    func contentsOfDirectory(atPath path: String) throws -> [String] { return try handler.mockThrowing(args: [path]) }
    func isDirectoryEmpty(at url: URL) -> Bool { return handler.mock(args: [url]) }
    func isDirectoryEmpty(atPath path: String) -> Bool { return handler.mock(args: [path]) }
    
    func createFile(atPath: String, contents: Data?, attributes: [FileAttributeKey : Any]?) -> Bool {
        return handler.mock(args: [atPath, contents, attributes])
    }
    
    func createDirectory(atPath: String, withIntermediateDirectories: Bool, attributes: [FileAttributeKey: Any]?) throws {
        try handler.mockThrowingNoReturn(args: [atPath, withIntermediateDirectories, attributes])
    }
    
    func createDirectory(at url: URL, withIntermediateDirectories: Bool, attributes: [FileAttributeKey: Any]?) throws {
        try handler.mockThrowingNoReturn(args: [url, withIntermediateDirectories, attributes])
    }
    
    func copyItem(atPath: String, toPath: String) throws { return try handler.mockThrowing(args: [atPath, toPath]) }
    func copyItem(at fromUrl: URL, to toUrl: URL) throws { return try handler.mockThrowing(args: [fromUrl, toUrl]) }
    func moveItem(atPath: String, toPath: String) throws { return try handler.mockThrowing(args: [atPath, toPath]) }
    func moveItem(at fromUrl: URL, to toUrl: URL) throws { return try handler.mockThrowing(args: [fromUrl, toUrl]) }
    func replaceItem(
        atPath originalItemPath: String,
        withItemAtPath newItemPath: String,
        backupItemName: String?,
        options: FileManager.ItemReplacementOptions
    ) throws -> String? {
        return try handler.mockThrowing(args: [originalItemPath, newItemPath, backupItemName, options])
    }
    func replaceItemAt(
        _ originalItemURL: URL,
        withItemAt newItemURL: URL,
        backupItemName: String?,
        options: FileManager.ItemReplacementOptions
    ) throws -> URL? {
        return try handler.mockThrowing(args: [originalItemURL, newItemURL, backupItemName, options])
    }
    func removeItem(atPath: String) throws { return try handler.mockThrowing(args: [atPath]) }
    
    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        return try handler.mockThrowing(args: [path])
    }
    
    func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        try handler.mockThrowingNoReturn(args: [attributes, path])
    }
}

// MARK: - Convenience

extension MockFileManager {
    func defaultInitialSetup() async throws {
        try await self.when { $0.appSharedDataDirectoryPath }.thenReturn("/test")
        try await self.when { $0.temporaryDirectoryAccessibleAfterFirstAuth }.thenReturn("/test_tmp1")
        try await self.when { try $0.ensureDirectoryExists(at: .any, fileProtectionType: .any) }.thenReturn(())
        try await self.when { try $0.protectFileOrFolder(at: .any, fileProtectionType: .any) }.thenReturn(())
        try await self.when { $0.fileExists(atPath: .any) }.thenReturn(false)
        try await self.when { $0.fileExists(atPath: .any, isDirectory: .any) }.thenReturn(false)
        try await self.when { $0.fileSize(of: .any) }.thenReturn(1024)
        try await self.when { $0.isLocatedInTemporaryDirectory(.any) }.thenReturn(false)
        try await self.when { $0.temporaryFilePath(fileExtension: .any) }.thenReturn("tmpFile")
        try await self.when { $0.createFile(atPath: .any, contents: .any, attributes: .any) }.thenReturn(true)
        try await self.when { try $0.write(dataToTemporaryFile: .any) }.thenReturn("tmpFile")
        try await self.when { try $0.write(data: .any, toPath: .any) }.thenReturn(())
        try await self.when { try $0.setAttributes(.any, ofItemAtPath: .any) }.thenReturn(())
        try await self.when { try $0.copyItem(atPath: .any, toPath: .any) }.thenReturn(())
        try await self.when { try $0.moveItem(atPath: .any, toPath: .any) }.thenReturn(())
        try await self.when {
            _ = try $0.replaceItem(
                atPath: .any,
                withItemAtPath: .any,
                backupItemName: .any,
                options: .any
            )
        }.thenReturn(nil)
        try await self.when {
            _ = try $0.replaceItemAt(
                .any,
                withItemAt: .any,
                backupItemName: .any,
                options: .any
            )
        }.thenReturn(nil)
        try await self.when { try $0.removeItem(atPath: .any) }.thenReturn(())
        try await self.when { try $0.contents(atPath: .any) }.thenReturn(Data([1, 2, 3]))
        try await self.when { $0.imageContents(atPath: .any) }.thenReturn(UIImage(data: TestConstants.validImageData))
        try await self.when { try $0.contentsOfDirectory(at: .any) }.thenReturn([])
        try await self.when { try $0.contentsOfDirectory(atPath: .any) }.thenReturn([])
        try await self.when {
            try $0.createDirectory(
                atPath: .any,
                withIntermediateDirectories: .any,
                attributes: .any
            )
        }.thenReturn(())
        try await self.when { $0.isDirectoryEmpty(atPath: .any) }.thenReturn(true)
    }
}
