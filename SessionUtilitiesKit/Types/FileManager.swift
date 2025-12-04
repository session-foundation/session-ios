// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

// MARK: - Singleton

public extension Singleton {
    static let fileManager: SingletonConfig<FileManagerType> = Dependencies.create(
        identifier: "fileManager",
        createInstance: { dependencies in SessionFileManager(using: dependencies) }
    )
}

// MARK: - FileManagerType

public protocol FileManagerType {
    var temporaryDirectory: String { get }
    var documentsDirectoryPath: String { get }
    var appSharedDataDirectoryPath: String { get }
    
    /// **Note:** We need to call this method on launch _and_ every time the app becomes active,
    /// since file protection may prevent it from succeeding in the background.
    func clearOldTemporaryDirectories()
    
    func ensureDirectoryExists(at path: String, fileProtectionType: FileProtectionType) throws
    func protectFileOrFolder(at path: String, fileProtectionType: FileProtectionType) throws
    func fileSize(of path: String) -> UInt64?
    
    func isLocatedInTemporaryDirectory(_ path: String) -> Bool
    func temporaryFilePath(fileExtension: String?) -> String
    func write(data: Data, toTemporaryFileWithExtension fileExtension: String?) throws -> String
    func write(data: Data, toPath path: String) throws
    
    // MARK: - Forwarded NSFileManager
    
    var currentDirectoryPath: String { get }
    
    func urls(for directory: FileManager.SearchPathDirectory, in domains: FileManager.SearchPathDomainMask) -> [URL]
    func enumerator(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options: FileManager.DirectoryEnumerationOptions,
        errorHandler: ((URL, Error) -> Bool)?
    ) -> FileManager.DirectoryEnumerator?
    
    func fileExists(atPath: String) -> Bool
    func fileExists(atPath: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool
    func contents(atPath: String) -> Data?
    func contents(atPath: String) throws -> Data
    func contentsOfDirectory(at url: URL) throws -> [URL]
    func contentsOfDirectory(atPath path: String) throws -> [String]
    func isDirectoryEmpty(at url: URL) -> Bool
    func isDirectoryEmpty(atPath path: String) -> Bool
    
    func createFile(atPath: String, contents: Data?, attributes: [FileAttributeKey: Any]?) -> Bool
    func createDirectory(at url: URL, withIntermediateDirectories: Bool, attributes: [FileAttributeKey: Any]?) throws
    func createDirectory(atPath: String, withIntermediateDirectories: Bool, attributes: [FileAttributeKey: Any]?) throws
    func copyItem(atPath: String, toPath: String) throws
    func copyItem(at fromUrl: URL, to toUrl: URL) throws
    func moveItem(atPath: String, toPath: String) throws
    func moveItem(at fromUrl: URL, to toUrl: URL) throws
    func replaceItem(atPath originalItemPath: String, withItemAtPath newItemPath: String, backupItemName: String?, options: FileManager.ItemReplacementOptions) throws -> String?
    func replaceItemAt(_ originalItemURL: URL, withItemAt newItemURL: URL, backupItemName: String?, options: FileManager.ItemReplacementOptions) throws -> URL?
    func removeItem(atPath: String) throws
    
    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any]
    func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws
}

public extension FileManagerType {
    func ensureDirectoryExists(at path: String) throws {
        try ensureDirectoryExists(at: path, fileProtectionType: .completeUntilFirstUserAuthentication)
    }
    
    func protectFileOrFolder(at path: String) throws {
        try protectFileOrFolder(at: path, fileProtectionType: .completeUntilFirstUserAuthentication)
    }
    
    func temporaryFilePath() -> String {
        return temporaryFilePath(fileExtension: nil)
    }
    
    func write(dataToTemporaryFile data: Data) throws -> String {
        return try write(data: data, toTemporaryFileWithExtension: nil)
    }
    
    func enumerator(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?) -> FileManager.DirectoryEnumerator? {
        return enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: nil)
    }
    
    func enumerator(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options: FileManager.DirectoryEnumerationOptions
    ) -> FileManager.DirectoryEnumerator? {
        return enumerator(at: url, includingPropertiesForKeys: keys, options: options, errorHandler: nil)
    }
    
    func enumerator(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        errorHandler: ((URL, Error) -> Bool)?
    ) -> FileManager.DirectoryEnumerator? {
        return enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: errorHandler)
    }
    
    func createFile(atPath: String, contents: Data?) -> Bool {
        return createFile(atPath: atPath, contents: contents, attributes: nil)
    }
    
    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
        try createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories, attributes: nil)
    }
    
    func createDirectory(atPath: String, withIntermediateDirectories: Bool) throws {
        try createDirectory(atPath: atPath, withIntermediateDirectories: withIntermediateDirectories, attributes: nil)
    }
    
    func replaceItem(atPath originalItemPath: String, withItemAtPath newItemPath: String) throws -> String? {
        return try replaceItem(atPath: originalItemPath, withItemAtPath: newItemPath, backupItemName: nil, options: [])
    }
    
    func replaceItemAt(_ originalItemURL: URL, withItemAt newItemURL: URL) throws -> URL? {
        return try replaceItemAt(originalItemURL, withItemAt: newItemURL, backupItemName: nil, options: [])
    }
}

// MARK: - Convenience

public extension SessionFileManager {
    static var cachesDirectoryPath: String {
        return NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true)[0]
    }
    
    static var nonInjectedAppSharedDataDirectoryPath: String {
        return (FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: UserDefaults.applicationGroup)?
            .path)
            .defaulting(to: "")
    }
}

// MARK: - SessionFileManager

public class SessionFileManager: FileManagerType {
    private static let temporaryDirectoryPrefix: String = "sesh_temp_"
    
    private let dependencies: Dependencies
    private let fileManager: FileManager = .default
    public var temporaryDirectory: String
    
    public var documentsDirectoryPath: String {
        return (fileManager.urls(for: .documentDirectory, in: .userDomainMask).first?.path)
            .defaulting(to: "")
    }
    
    public var appSharedDataDirectoryPath: String {
        return (fileManager.containerURL(forSecurityApplicationGroupIdentifier: UserDefaults.applicationGroup)?.path)
            .defaulting(to: "")
    }
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        
        /// Create a new temp directory for this instance
        ///
        /// **Note:** THe `ExtensionHelper` writes files to this folder temporarily before moving them to their final destination
        /// and, as of iOS 26, files seem to keep the `fileProtectionType` from the location they were created in instead of from
        /// the location they currently exist in. As such the temporary directory **must** use`completeUntilFirstUserAuthentication`
        /// or the extensions won't function correctly
        let dirName: String = "\(SessionFileManager.temporaryDirectoryPrefix)\(UUID().uuidString)"
        self.temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(dirName)
            .path
        try? ensureDirectoryExists(
            at: self.temporaryDirectory,
            fileProtectionType: .completeUntilFirstUserAuthentication
        )
    }
    
    // MARK: - Functions
    
    public func clearOldTemporaryDirectories() {
        /// We use the lowest priority queue for this, and wait N seconds to avoid interfering with app startup
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + .seconds(3), using: dependencies) { [temporaryDirectory, fileManager, dependencies] in
            /// Abort if app not active
            guard dependencies[singleton: .appContext].isAppForegroundAndActive else { return }
            
            /// Ignore the "current" temp directory
            let thresholdDate: Date = dependencies[singleton: .appContext].appLaunchTime
            let currentTempDirName: String = URL(fileURLWithPath: temporaryDirectory).lastPathComponent
            let dirPath: String = NSTemporaryDirectory()
            
            guard let fileNames: [String] = try? fileManager.contentsOfDirectory(atPath: dirPath) else {
                return
            }
            
            fileNames.forEach { fileName in
                guard fileName != currentTempDirName else { return }
                
                /// Delete files with either:
                ///
                /// a) `temporaryDirectoryPrefix` name prefix.
                /// b) modified time before app launch time.
                let filePath: String = URL(fileURLWithPath: dirPath).appendingPathComponent(fileName).path
                
                if !fileName.hasPrefix(SessionFileManager.temporaryDirectoryPrefix) {
                    /// It's fine if we can't get the attributes (the file may have been deleted since we found it), also don't delete
                    /// files which were created in the last N minutes
                    guard
                        let attributes: [FileAttributeKey: Any] = try? fileManager.attributesOfItem(atPath: filePath),
                        let modificationDate: Date = attributes[.modificationDate] as? Date,
                        modificationDate.timeIntervalSince1970 <= thresholdDate.timeIntervalSince1970
                    else { return }
                }
                
                /// This can happen if the app launches before the phone is unlocked, clean up will occur when app becomes active
                try? fileManager.removeItem(atPath: filePath)
            }
        }
    }
    
    public func ensureDirectoryExists(at path: String, fileProtectionType: FileProtectionType) throws {
        var isDirectory: ObjCBool = false
        
        if !fileManager.fileExists(atPath: path, isDirectory: &isDirectory) {
            try fileManager.createDirectory(
                atPath: path,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }
        
        try protectFileOrFolder(at: path, fileProtectionType: fileProtectionType)
    }
    
    public func protectFileOrFolder(at path: String, fileProtectionType: FileProtectionType) throws {
        guard fileManager.fileExists(atPath: path) else { return }
        
        try fileManager.setAttributes(
            [.protectionKey: fileProtectionType],
            ofItemAtPath: path
        )
        
        var resourcesUrl: URL = URL(fileURLWithPath: path)
        var resourceAttrs: URLResourceValues = URLResourceValues()
        resourceAttrs.isExcludedFromBackup = true
        try resourcesUrl.setResourceValues(resourceAttrs)
    }
    
    public func fileSize(of path: String) -> UInt64? {
        guard let attributes: [FileAttributeKey: Any] = try? fileManager.attributesOfItem(atPath: path) else {
            return nil
        }
        
        return (attributes[.size] as? UInt64)
    }
    
    public func isLocatedInTemporaryDirectory(_ path: String) -> Bool {
        let prefix: String = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(SessionFileManager.temporaryDirectoryPrefix)
            .path
        
        return path.hasPrefix(prefix)
    }
    
    public func temporaryFilePath(fileExtension: String?) -> String {
        var tempFileName: String = UUID().uuidString
        
        if let fileExtension: String = fileExtension, !fileExtension.isEmpty {
            tempFileName = "\(tempFileName).\(fileExtension)"
        }
        
        return URL(fileURLWithPath: temporaryDirectory)
            .appendingPathComponent(tempFileName)
            .path
    }
    
    public func write(data: Data, toTemporaryFileWithExtension fileExtension: String?) throws -> String {
        let tempFilePath: String = temporaryFilePath(fileExtension: fileExtension)
        
        try data.write(to: URL(fileURLWithPath: tempFilePath), options: .atomic)
        try protectFileOrFolder(at: tempFilePath)
        
        return tempFilePath
    }
    
    public func write(data: Data, toPath path: String) throws {
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try protectFileOrFolder(at: path)
    }
    
    // MARK: - Forwarded NSFileManager
    
    public var currentDirectoryPath: String { fileManager.currentDirectoryPath }
    
    public func urls(for directory: FileManager.SearchPathDirectory, in domains: FileManager.SearchPathDomainMask) -> [URL] {
        
        return fileManager.urls(for: directory, in: domains)
    }
    
    public func enumerator(
        at url: URL,
        includingPropertiesForKeys: [URLResourceKey]?,
        options: FileManager.DirectoryEnumerationOptions,
        errorHandler: ((URL, Error) -> Bool)?
    ) -> FileManager.DirectoryEnumerator? {
        return fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: includingPropertiesForKeys,
            options: options,
            errorHandler: errorHandler
        )
    }
    
    public func fileExists(atPath: String) -> Bool {
        return fileManager.fileExists(atPath: atPath)
    }
    
    public func fileExists(atPath: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        return fileManager.fileExists(atPath: atPath, isDirectory: isDirectory)
    }
    
    public func contents(atPath: String) -> Data? {
        return fileManager.contents(atPath: atPath)
    }
    
    public func contents(atPath: String) throws -> Data {
        return try Data(contentsOf: URL(fileURLWithPath: atPath))
    }
    
    public func contentsOfDirectory(at url: URL) throws -> [URL] {
        return try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
    }
    
    public func contentsOfDirectory(atPath path: String) throws -> [String] {
        return try fileManager.contentsOfDirectory(atPath: path)
    }
    
    public func isDirectoryEmpty(at url: URL) -> Bool {
        guard
            let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
        ) else { return false }

        /// If `nextObject()` returns `nil` immediately, there were no items
        return enumerator.nextObject() == nil
    }
    
    public func isDirectoryEmpty(atPath path: String) -> Bool {
        return isDirectoryEmpty(at: URL(fileURLWithPath: path))
    }

    public func createFile(atPath: String, contents: Data?, attributes: [FileAttributeKey: Any]?) -> Bool {
        return fileManager.createFile(atPath: atPath, contents: contents, attributes: attributes)
    }
    
    public func createDirectory(at url: URL, withIntermediateDirectories: Bool, attributes: [FileAttributeKey: Any]?) throws {
        return try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: withIntermediateDirectories,
            attributes: attributes
        )
    }
    
    public func createDirectory(atPath: String, withIntermediateDirectories: Bool, attributes: [FileAttributeKey: Any]?) throws {
        return try fileManager.createDirectory(
            atPath: atPath,
            withIntermediateDirectories: withIntermediateDirectories,
            attributes: attributes
        )
    }
    
    public func copyItem(atPath: String, toPath: String) throws {
        return try fileManager.copyItem(atPath: atPath, toPath: toPath)
    }
    
    public func copyItem(at fromUrl: URL, to toUrl: URL) throws {
        return try fileManager.copyItem(at: fromUrl, to: toUrl)
    }
    
    public func moveItem(atPath: String, toPath: String) throws {
        try fileManager.moveItem(atPath: atPath, toPath: toPath)
    }
    
    public func moveItem(at fromUrl: URL, to toUrl: URL) throws {
        try fileManager.moveItem(at: fromUrl, to: toUrl)
    }
    
    public func replaceItem(atPath originalItemPath: String, withItemAtPath newItemPath: String, backupItemName: String?, options: FileManager.ItemReplacementOptions) throws -> String? {
        return try fileManager.replaceItemAt(
            URL(fileURLWithPath: originalItemPath),
            withItemAt: URL(fileURLWithPath: newItemPath),
            backupItemName: backupItemName,
            options: options
        )?.path
    }
    
    public func replaceItemAt(_ originalItemURL: URL, withItemAt newItemURL: URL, backupItemName: String?, options: FileManager.ItemReplacementOptions) throws -> URL? {
        return try fileManager.replaceItemAt(originalItemURL, withItemAt: newItemURL, backupItemName: backupItemName, options: options)
    }
    
    public func removeItem(atPath: String) throws {
        return try fileManager.removeItem(atPath: atPath)
    }
    
    public func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        return try fileManager.attributesOfItem(atPath: path)
    }
    
    public func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        return try fileManager.setAttributes(attributes, ofItemAtPath: path)
    }
}
