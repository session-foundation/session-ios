// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import CryptoKit
import Compression

enum ArchiveError: Error {
    case invalidSourcePath
    case archiveFailed
    case unarchiveFailed
}

public class DirectoryArchiver {
    /// Archive an entire directory
    /// - Parameters:
    ///   - sourcePath: Full path to the directory to compress
    ///   - destinationPath: Full path where the compressed file will be saved
    ///   - password: Optional password for encryption
    /// - Throws: ArchiveError if archiving fails
    public static func archiveDirectory(
        sourcePath: String,
        destinationPath: String,
        additionalPaths: [String] = [],
        password: String?,
        progressChanged: ((Int, Int, UInt64, UInt64) -> Void)?
    ) throws {
        guard FileManager.default.fileExists(atPath: sourcePath) else {
            throw ArchiveError.invalidSourcePath
        }
        
        let sourceUrl: URL = URL(fileURLWithPath: sourcePath)
        let destinationUrl: URL = URL(fileURLWithPath: destinationPath)
        
        // Create output stream for backup and compression
        guard let outputStream: OutputStream = OutputStream(url: destinationUrl, append: false) else {
            throw ArchiveError.archiveFailed
        }
        
        outputStream.open()
        defer { outputStream.close() }
        
        // Stream-based directory traversal and compression
        let enumerator: FileManager.DirectoryEnumerator? = FileManager.default.enumerator(
            at: sourceUrl,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        let fileUrls: [URL] = (enumerator?.allObjects.compactMap { $0 as? URL } ?? [])
            .appending(contentsOf: additionalPaths.map { URL(fileURLWithPath: $0) })
        var index: Int = 0
        progressChanged?(index, fileUrls.count, 0, 0)
        
        try fileUrls.forEach { url in
            index += 1
            
            try exportFile(
                sourcePath: sourcePath,
                fileURL: url,
                outputStream: outputStream,
                password: password,
                index: index,
                totalFiles: (fileUrls.count + additionalPaths.count),
                isExtraFile: false,
                progressChanged: progressChanged
            )
        }
        
        // Add any extra files which we want to include
        try additionalPaths.forEach { path in
            index += 1
            // TODO: Need to fix these so that the path replacement with `sourcePath` isn't busted
            try exportFile(
                sourcePath: sourcePath,
                fileURL: URL(fileURLWithPath: path),
                outputStream: outputStream,
                password: password,
                index: index,
                totalFiles: (fileUrls.count + additionalPaths.count),
                isExtraFile: true,
                progressChanged: progressChanged
            )
        }
    }
    
    private static func exportFile(
        sourcePath: String,
        fileURL: URL,
        outputStream: OutputStream,
        password: String?,
        index: Int,
        totalFiles: Int,
        isExtraFile: Bool,
        progressChanged: ((Int, Int, UInt64, UInt64) -> Void)?
    ) throws {
        guard
            let values: URLResourceValues = try? fileURL.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]
            ),
            values.isRegularFile == true,
            var fileSize: UInt64 = values.fileSize.map({ UInt64($0) })
        else {
            progressChanged?(index, totalFiles, 1, 1)
            return
        }
        
        // Relative path preservation
        let relativePath: String = fileURL.path.replacingOccurrences(
            of: sourcePath,
            with: ""
        ).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        
        // Write path length and path
        let pathData: Data = relativePath.data(using: .utf8)!
        var pathLength: UInt32 = UInt32(pathData.count)
        var isExtraFile: Bool = isExtraFile
        
        // Encrypt and write metadata (path length + path data)
        let metadata: Data = (
            Data(bytes: &pathLength, count: MemoryLayout<UInt32>.size) +
            pathData +
            Data(bytes: &fileSize, count: MemoryLayout<UInt64>.size) +
            Data(bytes: &isExtraFile, count: MemoryLayout<Bool>.size)
        )
        let processedMetadata: [UInt8]
        
        switch password {
            case .none: processedMetadata = Array(metadata)
            case .some(let password):
                processedMetadata = try encrypt(
                    buffer: Array(metadata),
                    password: password
                )
        }
        
        var blockSize: UInt64 = UInt64(processedMetadata.count)
        let blockSizeData: [UInt8] = Array(Data(bytes: &blockSize, count: MemoryLayout<UInt64>.size))
        outputStream.write(blockSizeData, maxLength: blockSizeData.count)
        outputStream.write(processedMetadata, maxLength: processedMetadata.count)
        
        // Stream file contents
        guard let inputStream: InputStream = InputStream(url: fileURL) else {
            progressChanged?(index, totalFiles, 1, 1)
            return
        }
        
        inputStream.open()
        defer { inputStream.close() }
        
        var buffer: [UInt8] = [UInt8](repeating: 0, count: 4096)
        var currentFileProcessAmount: UInt64 = 0
        while inputStream.hasBytesAvailable {
            let bytesRead: Int = inputStream.read(&buffer, maxLength: buffer.count)
            currentFileProcessAmount += UInt64(bytesRead)
            progressChanged?(index, totalFiles, currentFileProcessAmount, fileSize)
            
            if bytesRead > 0 {
                let processedBytes: [UInt8]
                
                switch password {
                    case .none: processedBytes = buffer
                    case .some(let password):
                        processedBytes = try encrypt(
                            buffer: Array(buffer.prefix(bytesRead)),
                            password: password
                        )
                }
                
                var chunkSize: UInt32 = UInt32(processedBytes.count)
                let chunkSizeData: [UInt8] = Array(Data(bytes: &chunkSize, count: MemoryLayout<UInt32>.size))
                outputStream.write(chunkSizeData, maxLength: chunkSizeData.count)
                outputStream.write(processedBytes, maxLength: processedBytes.count)
            }
        }
    }
    
    public static func unarchiveDirectory(
        archivePath: String,
        destinationPath: String,
        password: String?,
        progressChanged: ((UInt64, UInt64) -> Void)?
    ) throws -> [String] {
        // Remove any old imported data as we don't want to muddy the new data
        if FileManager.default.fileExists(atPath: destinationPath) {
            try? FileManager.default.removeItem(atPath: destinationPath)
        }
        
        // Create the destination directory
        try FileManager.default.createDirectory(
            atPath: destinationPath,
            withIntermediateDirectories: true
        )
        
        guard
            let values: URLResourceValues = try? URL(fileURLWithPath: archivePath).resourceValues(
                forKeys: [.fileSizeKey]
            ),
            let encryptedFileSize: UInt64 = values.fileSize.map({ UInt64($0) }),
            let inputStream: InputStream = InputStream(fileAtPath: archivePath)
        else { throw ArchiveError.unarchiveFailed }
        
        inputStream.open()
        defer { inputStream.close() }
        
        var extraFilePaths: [String] = []
        var fileAmountProcessed: UInt64 = 0
        progressChanged?(0, encryptedFileSize)
        while inputStream.hasBytesAvailable {
            // Read block size
            var blockSizeBytes: [UInt8] = [UInt8](repeating: 0, count: MemoryLayout<UInt64>.size)
            let bytesRead: Int = inputStream.read(&blockSizeBytes, maxLength: blockSizeBytes.count)
            fileAmountProcessed += UInt64(bytesRead)
            progressChanged?(fileAmountProcessed, encryptedFileSize)
            
            switch bytesRead {
                case 0: continue                            // We have finished reading
                case blockSizeBytes.count: break            // We have started the next block
                default: throw ArchiveError.unarchiveFailed // Invalid
            }
            
            var blockSize: UInt64 = 0
            _ = withUnsafeMutableBytes(of: &blockSize) { blockSizeBuffer in
                blockSizeBytes.copyBytes(to: blockSizeBuffer, from: ..<MemoryLayout<UInt64>.size)
            }
            
            // Read and decrypt metadata
            var encryptedMetadata: [UInt8] = [UInt8](repeating: 0, count: Int(blockSize))
            guard inputStream.read(&encryptedMetadata, maxLength: encryptedMetadata.count) == encryptedMetadata.count else {
                throw ArchiveError.unarchiveFailed
            }
            
            let metadata: [UInt8]
            switch password {
                case .none: metadata = encryptedMetadata
                case .some(let password): metadata = try decrypt(buffer: encryptedMetadata, password: password)
            }
            var offset = 0
            
            // Extract path length and path
            let pathLengthRange: Range<Int> = offset..<(offset + MemoryLayout<UInt32>.size)
            var pathLength: UInt32 = 0
            _ = withUnsafeMutableBytes(of: &pathLength) { pathLengthBuffer in
                metadata.copyBytes(to: pathLengthBuffer, from: pathLengthRange)
            }
            offset += MemoryLayout<UInt32>.size
            
            let pathRange: Range<Int> = offset..<(offset + Int(pathLength))
            let relativePath: String = String(data: Data(metadata[pathRange]), encoding: .utf8)!
            offset += Int(pathLength)
            
            // Extract file size
            let fileSizeRange: Range<Int> = offset..<(offset + MemoryLayout<UInt64>.size)
            var fileSize: UInt64 = 0
            _ = withUnsafeMutableBytes(of: &fileSize) { fileSizeBuffer in
                metadata.copyBytes(to: fileSizeBuffer, from: fileSizeRange)
            }
            offset += Int(MemoryLayout<UInt64>.size)
            
            // Extract extra file flag
            let isExtraFileRange: Range<Int> = offset..<(offset + MemoryLayout<Bool>.size)
            var isExtraFile: Bool = false
            _ = withUnsafeMutableBytes(of: &isExtraFile) { isExtraFileBuffer in
                metadata.copyBytes(to: isExtraFileBuffer, from: isExtraFileRange)
            }
            
            // Construct full file path
            let fullPath: String = (destinationPath as NSString).appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                atPath: (fullPath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            fileAmountProcessed += UInt64(encryptedMetadata.count)
            progressChanged?(fileAmountProcessed, encryptedFileSize)
            
            // Read and decrypt file content
            guard let outputStream: OutputStream = OutputStream(toFileAtPath: fullPath, append: false) else {
                throw ArchiveError.unarchiveFailed
            }
            outputStream.open()
            defer { outputStream.close() }
            
            var remainingFileSize: Int = Int(fileSize)
            while remainingFileSize > 0 {
                // Read chunk size
                var chunkSizeBytes: [UInt8] = [UInt8](repeating: 0, count: MemoryLayout<UInt32>.size)
                guard inputStream.read(&chunkSizeBytes, maxLength: chunkSizeBytes.count) == chunkSizeBytes.count else {
                    throw ArchiveError.unarchiveFailed
                }
                var chunkSize: UInt32 = 0
                _ = withUnsafeMutableBytes(of: &chunkSize) { chunkSizeBuffer in
                    chunkSizeBytes.copyBytes(to: chunkSizeBuffer, from: ..<MemoryLayout<UInt32>.size)
                }
                fileAmountProcessed += UInt64(chunkSizeBytes.count)
                progressChanged?(fileAmountProcessed, encryptedFileSize)
                
                // Read the chunk
                var chunkBytes: [UInt8] = [UInt8](repeating: 0, count: Int(chunkSize))
                guard inputStream.read(&chunkBytes, maxLength: chunkBytes.count) == chunkBytes.count else {
                    throw ArchiveError.unarchiveFailed
                }
                
                let processedChunk: [UInt8]
                switch password {
                    case .none: processedChunk = chunkBytes
                    case .some(let password): processedChunk = try decrypt(buffer: chunkBytes, password: password)
                }
                
                outputStream.write(processedChunk, maxLength: processedChunk.count)
                remainingFileSize -= processedChunk.count
                
                fileAmountProcessed += UInt64(chunkBytes.count)
                progressChanged?(fileAmountProcessed, encryptedFileSize)
            }
            
            if isExtraFile {
                extraFilePaths.append(fullPath)
            }
        }
        
        return extraFilePaths
    }
    
    private static func encrypt(buffer: [UInt8], password: String) throws -> [UInt8] {
        guard let passwordData: Data = password.data(using: .utf8) else {
            return buffer
        }
        
        // Use HKDF for key derivation
        let salt: Data = Data(count: 16)
        let key: SymmetricKey = SymmetricKey(data: passwordData)
        let symmetricKey: SymmetricKey = SymmetricKey(
            data: HKDF<SHA256>.deriveKey(
                inputKeyMaterial: key,
                salt: salt,
                outputByteCount: 32
            )
        )
        let nonce: AES.GCM.Nonce = AES.GCM.Nonce()
        let sealedBox: AES.GCM.SealedBox = try AES.GCM.seal(
            Data(buffer),
            using: symmetricKey,
            nonce: nonce
        )
        
        // Combine nonce, ciphertext, and tag
        return [UInt8](nonce) + sealedBox.ciphertext + sealedBox.tag
    }
    
    private static func decrypt(buffer: [UInt8], password: String) throws -> [UInt8] {
        guard let passwordData: Data = password.data(using: .utf8) else {
            return buffer
        }
        
        let salt: Data = Data(count: 16)
        let key: SymmetricKey = SymmetricKey(data: passwordData)
        let symmetricKey: SymmetricKey = SymmetricKey(
            data: HKDF<SHA256>.deriveKey(
                inputKeyMaterial: key,
                salt: salt,
                outputByteCount: 32
            )
        )
        
        // Extract nonce, ciphertext, and tag
        let nonce: AES.GCM.Nonce = try AES.GCM.Nonce(data: Data(buffer.prefix(12)))
        let ciphertext: Data = Data(buffer[12..<(buffer.count-16)])
        let tag: Data = Data(buffer.suffix(16))
        
        // Decrypt with AES-GCM
        let sealedBox: AES.GCM.SealedBox = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: ciphertext,
            tag: tag
        )
        
        let decryptedData: Data = try AES.GCM.open(sealedBox, using: symmetricKey)
        return [UInt8](decryptedData)
    }
}

fileprivate extension InputStream {
    func readEncryptedChunk(password: String, maxLength: Int) -> Data? {
        var buffer: [UInt8] = [UInt8](repeating: 0, count: maxLength)
        let bytesRead: Int = self.read(&buffer, maxLength: maxLength)
        guard bytesRead > 0 else { return nil }
        
        return Data(buffer.prefix(bytesRead))
    }
}
