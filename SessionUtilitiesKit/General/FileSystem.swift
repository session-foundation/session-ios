// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public enum FileSystem {
    /// **Note:** The max file size is 10,000,000 bytes (rather than 10MiB which would be `(10 * 1024 * 1024)`), 10,000,000
    /// exactly will be fine but a single byte more will result in an error
    public static let maxFileSize = 10_000_000
    
    /// The Objective-C `OWSFileSystem` needs to be able to generate a temporary directory but we don't want to spend the time
    /// to add Objective-C support to `Dependencies` since the goal is to refactor everything to Swift so this value should only be
    /// assigned by the `AppContext` class when it gets initialised
    @ThreadSafeObject private static var temporaryDirectory: String = ""
    
    public static var cachesDirectoryPath: String {
        return NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true)[0]
    }
    
    public static func ensureDirectoryExists(
        at path: String,
        fileProtectionType: FileProtectionType = .completeUntilFirstUserAuthentication,
        using dependencies: Dependencies = Dependencies()
    ) throws {
        var isDirectory: ObjCBool = false
        
        if !FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
            try FileManager.default.createDirectory(
                atPath: path,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }
        
        try protectFileOrFolder(at: path, fileProtectionType: fileProtectionType, using: dependencies)
    }
    
    public static func protectFileOrFolder(
        at path: String,
        fileProtectionType: FileProtectionType = .completeUntilFirstUserAuthentication,
        using dependencies: Dependencies = Dependencies()
    ) throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        
        try FileManager.default.setAttributes(
            [.protectionKey: fileProtectionType],
            ofItemAtPath: path
        )
        
        var resourcesUrl: URL = URL(fileURLWithPath: path)
        var resourceAttrs: URLResourceValues = URLResourceValues()
        resourceAttrs.isExcludedFromBackup = true
        try resourcesUrl.setResourceValues(resourceAttrs)
    }
    
    public static func fileSize(of path: String, using dependencies: Dependencies = Dependencies()) -> UInt64? {
        guard let attributes: [FileAttributeKey: Any] = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        
        return (attributes[.size] as? UInt64)
    }
    
    public static func setTemporaryDirectory(_ temporaryDirectory: String) {
        _temporaryDirectory.set(to: temporaryDirectory)
    }
    
    public static func temporaryFilePath(fileExtension: String?) -> String {
        let finalTemporaryDirectory: String = {
            if !temporaryDirectory.isEmpty {
                return temporaryDirectory
            }
            
            // Not ideal but fallback to creating a new temp directory
            let dirName: String = "ows_temp_\(UUID().uuidString)"   // stringlint:ignore
            let tempDir: String = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(dirName)
                .path
            try? FileSystem.ensureDirectoryExists(at: tempDir, fileProtectionType: .complete)
            
            return tempDir
        }()
        
        var tempFileName: String = UUID().uuidString
        
        if let fileExtension: String = fileExtension, !fileExtension.isEmpty {
            tempFileName = "\(tempFileName).\(fileExtension)"
        }
        
        return URL(fileURLWithPath: finalTemporaryDirectory)
            .appendingPathComponent(tempFileName)
            .path
    }
    
    public static func write(data: Data, toTemporaryFileWithExtension fileExtension: String?) throws -> String? {
        let tempFilePath: String = temporaryFilePath(fileExtension: fileExtension)
        
        try data.write(to: URL(fileURLWithPath: tempFilePath), options: .atomic)
        try protectFileOrFolder(at: tempFilePath)
        
        return tempFilePath
    }
    
    public static func deleteFile(at path: String) throws {
        try FileManager.default.removeItem(atPath: path)
    }
}
