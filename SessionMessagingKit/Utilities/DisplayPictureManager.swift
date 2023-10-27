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
            .appendingPathComponent("ProfileAvatars")   // stringlint:disable
            .path
        OWSFileSystem.ensureDirectoryExists(path)
        
        return path
    }()
    
    private static let displayPictureDirPath: String = {
        let path: String = DisplayPictureManager.sharedDataDisplayPictureDirPath
        OWSFileSystem.ensureDirectoryExists(path)
        
        return path
    }()
    
    public static func isTooLong(profileUrl: String) -> Bool {
        return (profileUrl.utf8CString.count > SessionUtil.sizeMaxProfileUrlBytes)
    }
    
    // MARK: - Loading
    
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
    
    // MARK: - Encryption
    
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
        return UUID().uuidString.appendingFileExtension("jpg")  // stringlint:disable
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
    
    // MARK: - Downloading
    
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
    
    // MARK: - Uploading
    
    public static func prepareAndUploadDisplayPicture(
        queue: DispatchQueue,
        imageData: Data,
        success: @escaping ((downloadUrl: String, fileName: String, profileKey: Data)) -> (),
        failure: ((DisplayPictureError) -> ())? = nil,
        using dependencies: Dependencies
    ) {
        queue.async {
            // If the profile avatar was updated or removed then encrypt with a new profile key
            // to ensure that other users know that our profile picture was updated
            let newProfileKey: Data
            let finalImageData: Data
            let fileExtension: String
            
            do {
                let guessedFormat: ImageFormat = imageData.guessedImageFormat
                
                finalImageData = try {
                    switch guessedFormat {
                        case .gif, .webp:
                            // Animated images can't be resized so if the data is too large we should error
                            guard imageData.count <= DisplayPictureManager.maxBytes else {
                                // Our avatar dimensions are so small that it's incredibly unlikely we wouldn't
                                // be able to fit our profile photo (eg. generating pure noise at our resolution
                                // compresses to ~200k)
                                SNLog("Animated profile avatar was too large.")
                                SNLog("Updating service with profile failed.")
                                throw DisplayPictureError.uploadMaxFileSizeExceeded
                            }
                            
                            return imageData
                            
                        default: break
                    }
                    
                    // Process the image to ensure it meets our standards for size and compress it to
                    // standardise the formwat and remove any metadata
                    guard var image: UIImage = UIImage(data: imageData) else {
                        throw DisplayPictureError.invalidCall
                    }
                    
                    if image.size.width != DisplayPictureManager.maxDiameter || image.size.height != DisplayPictureManager.maxDiameter {
                        // To help ensure the user is being shown the same cropping of their avatar as
                        // everyone else will see, we want to be sure that the image was resized before this point.
                        SNLog("Avatar image should have been resized before trying to upload")
                        image = image.resizedImage(toFillPixelSize: CGSize(width: DisplayPictureManager.maxDiameter, height: DisplayPictureManager.maxDiameter))
                    }
                    
                    guard let data: Data = image.jpegData(compressionQuality: 0.95) else {
                        SNLog("Updating service with profile failed.")
                        throw DisplayPictureError.writeFailed
                    }
                    
                    guard data.count <= DisplayPictureManager.maxBytes else {
                        // Our avatar dimensions are so small that it's incredibly unlikely we wouldn't
                        // be able to fit our profile photo (eg. generating pure noise at our resolution
                        // compresses to ~200k)
                        SNLog("Suprised to find profile avatar was too large. Was it scaled properly? image: \(image)")
                        SNLog("Updating service with profile failed.")
                        throw DisplayPictureError.uploadMaxFileSizeExceeded
                    }
                    
                    return data
                }()
                
                newProfileKey = try Randomness.generateRandomBytes(numberBytes: DisplayPictureManager.aes256KeyByteLength)
                fileExtension = {
                    switch guessedFormat {
                        case .gif: return "gif"     // stringlint:disable
                        case .webp: return "webp"   // stringlint:disable
                        default: return "jpg"       // stringlint:disable
                    }
                }()
            }
            catch let error as DisplayPictureError { return (failure?(error) ?? {}()) }
            catch { return (failure?(DisplayPictureError.invalidCall) ?? {}()) }

            // If we have a new avatar image, we must first:
            //
            // * Write it to disk.
            // * Encrypt it
            // * Upload it to asset service
            // * Send asset service info to Signal Service
            SNLog(.verbose, "Updating local profile on service with new avatar.")
            
            let fileName: String = UUID().uuidString.appendingFileExtension(fileExtension)
            let filePath: String = DisplayPictureManager.filepath(for: fileName)
            
            // Write the avatar to disk
            do { try finalImageData.write(to: URL(fileURLWithPath: filePath), options: [.atomic]) }
            catch {
                SNLog("Updating service with profile failed.")
                failure?(.writeFailed)
                return
            }
            
            // Encrypt the avatar for upload
            guard let encryptedData: Data = DisplayPictureManager.encryptData(data: finalImageData, key: newProfileKey) else {
                SNLog("Updating service with profile failed.")
                failure?(.encryptionFailed)
                return
            }
            
            // Upload the avatar to the FileServer
            guard let preparedUpload: HTTP.PreparedRequest<FileUploadResponse> = try? FileServerAPI.preparedUpload(encryptedData, using: dependencies) else {
                SNLog("Updating service with profile failed.")
                failure?(.uploadFailed)
                return
            }
            
            preparedUpload
                .send(using: dependencies)
                .subscribe(on: DispatchQueue.global(qos: .userInitiated))
                .receive(on: queue)
                .sinkUntilComplete(
                    receiveCompletion: { result in
                        switch result {
                            case .finished: break
                            case .failure(let error):
                                SNLog("Updating service with profile failed.")
                                
                                let isMaxFileSizeExceeded: Bool = ((error as? HTTPError) == .maxFileSizeExceeded)
                                failure?(isMaxFileSizeExceeded ? .uploadMaxFileSizeExceeded : .uploadFailed)
                        }
                    },
                    receiveValue: { _, fileUploadResponse in
                        let downloadUrl: String = "\(FileServerAPI.server)/file/\(fileUploadResponse.id)"
                        
                        // Update the cached avatar image value
                        dependencies.mutate(cache: .displayPicture) { $0.imageData[fileName] = finalImageData }
                        
                        SNLog("Successfully uploaded avatar image.")
                        success((downloadUrl, fileName, newProfileKey))
                    }
                )
        }
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
