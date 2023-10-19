// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import CryptoKit
import Combine
import GRDB
import SignalCoreKit
import SessionSnodeKit
import SessionUtilitiesKit

public struct DisplayPictureManager {
    public enum Update {
        case none
        case remove
        case uploadImageData(Data)
        case updateTo(url: String, key: Data, fileName: String?)
    }
    
    public static let maxBytes: UInt = (5 * 1000 * 1000)
    public static let maxDiameter: CGFloat = 640
    public static let aes256KeyByteLength: Int = 32
    private static let nonceLength: Int = 12
    private static let tagLength: Int = 16
    
    private static var scheduleDownloadsPublisher: AnyPublisher<Void, Never>?
    private static let scheduleDownloadsTrigger: PassthroughSubject<(), Never> = PassthroughSubject()
    
    public static let sharedDataDisplayPictureDirPath: String = {
        let path: String = URL(fileURLWithPath: OWSFileSystem.appSharedDataDirectoryPath())
            .appendingPathComponent("ProfileAvatars")
            .path
        OWSFileSystem.ensureDirectoryExists(path)
        
        return path
    }()
    
    private static let displayPictureDirPath: String = {
        let path: String = DisplayPictureManager.sharedDataDisplayPictureDirPath
        OWSFileSystem.ensureDirectoryExists(path)
        
        return path
    }()
    
    // MARK: - Functions        
    
    public static func isToLong(profileUrl: String) -> Bool {
        return (profileUrl.utf8CString.count > SessionUtil.sizeMaxProfileUrlBytes)
    }
    
    public static func displayPicture(
        _ db: Database,
        id: OwnerId,
        using dependencies: Dependencies = Dependencies()
    ) -> Data? {
        let maybeOwner: Owner? = {
            switch id {
                case .user(let id): return try? Profile.fetchOne(db, id: id).map { Owner.user($0) }
                case .group(let id): return try? ClosedGroup.fetchOne(db, id: id).map { Owner.group($0) }
                case .community(let id): return try? OpenGroup.fetchOne(db, id: id).map { Owner.community($0) }
            }
        }()
        
        guard let owner: Owner = maybeOwner else { return nil }
        
        return displayPicture(owner: owner, using: dependencies)
    }
    
    @discardableResult public static func displayPicture(
        owner: Owner,
        using dependencies: Dependencies = Dependencies()
    ) -> Data? {
        switch (owner.fileName, owner.canDownloadImage) {
            case (.some(let fileName), _):
                return loadDisplayPicture(for: fileName, owner: owner, using: dependencies)
                
            case (_, true):
                scheduleDownload(for: owner, currentFileInvalid: false, using: dependencies)
                return nil
                
            default: return nil
        }
    }
    
    private static func loadDisplayPicture(
        for fileName: String,
        owner: Owner,
        using dependencies: Dependencies
    ) -> Data? {
        if let cachedImageData: Data = dependencies[cache: .displayPicture].imageData[fileName] {
            return cachedImageData
        }
        
        guard
            !fileName.isEmpty,
            let data: Data = loadDisplayPictureFromDisk(for: fileName),
            data.isValidImage
        else {
            // If we can't load the avatar or it's an invalid/corrupted image then clear it out and re-download
            scheduleDownload(for: owner, currentFileInvalid: true, using: dependencies)
            return nil
        }
        
        dependencies.mutate(cache: .displayPicture) { $0.imageData[fileName] = data }
        return data
    }
    
    public static func loadDisplayPictureFromDisk(for fileName: String) -> Data? {
        let filePath: String = DisplayPictureManager.filepath(for: fileName)

        return try? Data(contentsOf: URL(fileURLWithPath: filePath))
    }
    
    private static func scheduleDownload(
        for owner: Owner,
        currentFileInvalid invalid: Bool,
        using dependencies: Dependencies
    ) {
        dependencies.mutate(cache: .displayPicture) { cache in
            cache.downloadsToSchedule.insert(DownloadInfo(owner: owner, currentFileInvalid: invalid))
        }
        
        /// This method can be triggered very frequently when processing messages so we want to throttle the updates to 250ms (it's for starting
        /// avatar downloads so that should definitely be fast enough)
        if scheduleDownloadsPublisher == nil {
            scheduleDownloadsPublisher = scheduleDownloadsTrigger
                .throttle(for: .milliseconds(250), scheduler: DispatchQueue.global(qos: .userInitiated), latest: true)
                .handleEvents(
                    receiveOutput: { [dependencies] _ in
                        let pendingInfo: Set<DownloadInfo> = dependencies.mutate(cache: .displayPicture) { cache in
                            let result: Set<DownloadInfo> = cache.downloadsToSchedule
                            cache.downloadsToSchedule.removeAll()
                            return result
                        }
                        
                        dependencies[singleton: .storage].writeAsync(using: dependencies) { db in
                            pendingInfo.forEach { info in
                                // If the current file is invalid then clear out the 'profilePictureFileName'
                                // and try to re-download the file
                                if info.currentFileInvalid {
                                    info.owner.clearCurrentFile(db)
                                }
                                
                                dependencies[singleton: .jobRunner].add(
                                    db,
                                    job: Job(
                                        variant: .displayPictureDownload,
                                        shouldBeUnique: true,
                                        details: DisplayPictureDownloadJob.Details(owner: info.owner)
                                    ),
                                    canStartJob: true,
                                    using: dependencies
                                )
                            }
                        }
                    }
                )
                .map { _ in () }
                .eraseToAnyPublisher()
            
            scheduleDownloadsPublisher?.sinkUntilComplete()
        }
        
        scheduleDownloadsTrigger.send(())
    }
    
    // MARK: - Profile Encryption
    
    internal static func encryptData(data: Data, key: Data) -> Data? {
        // The key structure is: nonce || ciphertext || authTag
        guard
            key.count == DisplayPictureManager.aes256KeyByteLength,
            let nonceData: Data = try? Randomness.generateRandomBytes(numberBytes: DisplayPictureManager.nonceLength),
            let nonce: AES.GCM.Nonce = try? AES.GCM.Nonce(data: nonceData),
            let sealedData: AES.GCM.SealedBox = try? AES.GCM.seal(
                data,
                using: SymmetricKey(data: key),
                nonce: nonce
            ),
            let encryptedContent: Data = sealedData.combined
        else { return nil }
        
        return encryptedContent
    }
    
    internal static func decryptData(data: Data, key: Data) -> Data? {
        guard key.count == DisplayPictureManager.aes256KeyByteLength else { return nil }
        
        // The key structure is: nonce || ciphertext || authTag
        let cipherTextLength: Int = (data.count - (DisplayPictureManager.nonceLength + DisplayPictureManager.tagLength))
        
        guard
            cipherTextLength > 0,
            let sealedData: AES.GCM.SealedBox = try? AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: data.subdata(in: 0..<DisplayPictureManager.nonceLength)),
                ciphertext: data.subdata(in: DisplayPictureManager.nonceLength..<(DisplayPictureManager.nonceLength + cipherTextLength)),
                tag: data.subdata(in: (data.count - DisplayPictureManager.tagLength)..<data.count)
            ),
            let decryptedData: Data = try? AES.GCM.open(sealedData, using: SymmetricKey(data: key))
        else { return nil }
        
        return decryptedData
    }
    
    // MARK: - File Paths
    
    public static func profileAvatarFilepath(
        _ db: Database? = nil,
        id: String,
        using dependencies: Dependencies = Dependencies()
    ) -> String? {
        guard let db: Database = db else {
            return dependencies[singleton: .storage].read { db in profileAvatarFilepath(db, id: id) }
        }
        
        let maybeFileName: String? = try? Profile
            .filter(id: id)
            .select(.profilePictureFileName)
            .asRequest(of: String.self)
            .fetchOne(db)
        
        return maybeFileName.map { DisplayPictureManager.filepath(for: $0) }
    }
    
    public static func generateFilename() -> String {
        return UUID().uuidString.appendingFileExtension("jpg")
    }
    
    public static func filepath(for filename: String) -> String {
        guard !filename.isEmpty else { return "" }
        
        return URL(fileURLWithPath: sharedDataDisplayPictureDirPath)
            .appendingPathComponent(filename)
            .path
    }
    
    public static func resetStorage() {
        try? FileManager.default.removeItem(atPath: DisplayPictureManager.displayPictureDirPath)
    }
}

// MARK: - DisplayPictureManager.Owner

public extension DisplayPictureManager {
    enum OwnerId: Hashable {
        case user(String)
        case group(String)
        case community(String)
    }
    
    enum Owner: Hashable {
        case user(Profile)
        case group(ClosedGroup)
        case community(OpenGroup)
        case file(String)
        
        var fileName: String? {
            switch self {
                case .user(let profile): return profile.profilePictureFileName
                case .group(let group): return group.displayPictureFilename
                case .community(let openGroup): return openGroup.displayPictureFilename
                case .file(let name): return name
            }
        }
        
        var canDownloadImage: Bool {
            switch self {
                case .user(let profile): return (profile.profilePictureUrl?.isEmpty == false)
                case .group(let group): return (group.displayPictureUrl?.isEmpty == false)
                case .community(let openGroup): return (openGroup.imageId?.isEmpty == false)
                case .file: return false
            }
        }
        
        fileprivate func clearCurrentFile(_ db: Database) {
            switch self {
                case .user(let profile):
                    _ = try? Profile
                        .filter(id: profile.id)
                        .updateAll(db, Profile.Columns.profilePictureFileName.set(to: nil))
                    
                case .group(let group):
                    _ = try? ClosedGroup
                        .filter(id: group.id)
                        .updateAll(db, ClosedGroup.Columns.displayPictureFilename.set(to: nil))
                    
                case .community(let openGroup):
                    _ = try? OpenGroup
                        .filter(id: openGroup.id)
                        .updateAll(db, OpenGroup.Columns.displayPictureFilename.set(to: nil))
                    
                case .file: return
            }
        }
    }
}

// MARK: - DisplayPictureManager.DownloadInfo

public extension DisplayPictureManager {
    struct DownloadInfo: Hashable {
        let owner: Owner
        let currentFileInvalid: Bool
    }
}

// MARK: - DisplayPicture Cache

public extension DisplayPictureManager {
    class Cache: DisplayPictureCacheType {
        public var imageData: [String: Data] = [:]
        public var downloadsToSchedule: Set<DisplayPictureManager.DownloadInfo> = []
    }
}

public extension Cache {
    static let displayPicture: CacheConfig<DisplayPictureCacheType, DisplayPictureImmutableCacheType> = Dependencies.create(
        identifier: "displayPicture",
        createInstance: { _ in DisplayPictureManager.Cache() },
        mutableInstance: { $0 },
        immutableInstance: { $0 }
    )
}

// MARK: - DisplayPictureCacheType

/// This is a read-only version of the Cache designed to avoid unintentionally mutating the instance in a non-thread-safe way
public protocol DisplayPictureImmutableCacheType: ImmutableCacheType {
    var imageData: [String: Data] { get }
    var downloadsToSchedule: Set<DisplayPictureManager.DownloadInfo> { get }
}

public protocol DisplayPictureCacheType: DisplayPictureImmutableCacheType, MutableCacheType {
    var imageData: [String: Data] { get set }
    var downloadsToSchedule: Set<DisplayPictureManager.DownloadInfo> { get set }
}
