// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Combine
import GRDB
import SessionUIKit
import SessionSnodeKit
import SessionUtilitiesKit

// MARK: - Singleton

public extension Singleton {
    static let displayPictureManager: SingletonConfig<DisplayPictureManager> = Dependencies.create(
        identifier: "displayPictureManager",
        createInstance: { dependencies in DisplayPictureManager(using: dependencies) }
    )
}

// MARK: - Log.Category

public extension Log.Category {
    static let displayPictureManager: Log.Category = .create("DisplayPictureManager", defaultLevel: .info)
}

// MARK: - DisplayPictureManager

public class DisplayPictureManager {
    public typealias UploadResult = (downloadUrl: String, fileName: String, encryptionKey: Data)
    
    public enum Update {
        case none
        
        case contactRemove
        case contactUpdateTo(url: String, key: Data, fileName: String?, contactProProof: String?)
        
        case currentUserRemove
        case currentUserUploadImageData(data: Data, sessionProProof: String?)
        case currentUserUpdateTo(url: String, key: Data, fileName: String?, sessionProProof: String?)
        
        case groupRemove
        case groupUploadImageData(Data)
        case groupUpdateTo(url: String, key: Data, fileName: String?)
    }
    
    public static let maxBytes: UInt = (5 * 1000 * 1000)
    public static let maxDiameter: CGFloat = 640
    public static let aes256KeyByteLength: Int = 32
    internal static let nonceLength: Int = 12
    internal static let tagLength: Int = 16
    
    private let dependencies: Dependencies
    private let scheduleDownloads: PassthroughSubject<(), Never> = PassthroughSubject()
    private var scheduleDownloadsCancellable: AnyCancellable?
    
    // MARK: - Initalization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        
        setupThrottledDownloading()
    }
    
    // MARK: - General
    
    public static func isTooLong(profileUrl: String) -> Bool {
        /// String.utf8CString will include the null terminator (Int8)0 as the end of string buffer.
        /// When the string is exactly 100 bytes String.utf8CString.count will be 101.
        /// However in LibSession, the Contact C API supports 101 characters in order to account for
        /// the null terminator - char name[101]. So it is OK to use String.utf8.count
        return (profileUrl.utf8CString.count > LibSession.sizeMaxProfileUrlBytes)
    }
    
    public func sharedDataDisplayPictureDirPath() -> String {
        let path: String = URL(fileURLWithPath: dependencies[singleton: .fileManager].appSharedDataDirectoryPath)
            .appendingPathComponent("ProfileAvatars")   // stringlint:ignore
            .path
        try? dependencies[singleton: .fileManager].ensureDirectoryExists(at: path)
        
        return path
    }
    
    // MARK: - Loading
    
    public func loadDisplayPictureFromDisk(for fileName: String) -> Data? {
        guard let filePath: String = try? filepath(for: fileName) else { return nil }

        return try? Data(contentsOf: URL(fileURLWithPath: filePath))
    }
    
    // MARK: - File Paths
    
    /// **Note:** Generally the url we get won't have an extension and we don't want to make assumptions until we have the actual
    /// image data so generate a name for the file and then determine the extension separately
    public func generateFilenameWithoutExtension(for url: String) -> String {
        return (dependencies[singleton: .crypto]
            .generate(.hash(message: url.bytes))?
            .toHexString())
            .defaulting(to: UUID().uuidString)
    }
    
    public func generateFilename(format: ImageFormat = .jpeg) -> String {
        return dependencies[singleton: .crypto]
            .generate(.uuid())
            .defaulting(to: UUID())
            .uuidString
            .appendingFileExtension(format.fileExtension)
    }
    
    public func filepath(for filename: String) throws -> String {
        guard !filename.isEmpty else { throw DisplayPictureError.invalidCall }
        
        return URL(fileURLWithPath: sharedDataDisplayPictureDirPath())
            .appendingPathComponent(filename)
            .path
    }
    
    public func resetStorage() {
        try? dependencies[singleton: .fileManager].removeItem(
            atPath: sharedDataDisplayPictureDirPath()
        )
    }
    
    // MARK: - Downloading
    
    /// Profile picture downloads can be triggered very frequently when processing messages so we want to throttle the updates to
    /// 250ms (it's for starting avatar downloads so that should definitely be fast enough)
    private func setupThrottledDownloading() {
        scheduleDownloadsCancellable = scheduleDownloads
            .throttle(for: .milliseconds(250), scheduler: DispatchQueue.global(qos: .userInitiated), latest: true)
            .sink(
                receiveValue: { [dependencies] _ in
                    let pendingInfo: Set<DownloadInfo> = dependencies.mutate(cache: .displayPicture) { cache in
                        let result: Set<DownloadInfo> = cache.downloadsToSchedule
                        cache.downloadsToSchedule.removeAll()
                        return result
                    }
                    
                    dependencies[singleton: .storage].writeAsync { db in
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
                                canStartJob: true
                            )
                        }
                    }
                }
            )
    }
    
    public func scheduleDownload(for owner: Owner, currentFileInvalid invalid: Bool = false) {
        guard owner.canDownloadImage else { return }
        
        dependencies.mutate(cache: .displayPicture) { cache in
            cache.downloadsToSchedule.insert(DownloadInfo(owner: owner, currentFileInvalid: invalid))
        }
        scheduleDownloads.send(())
    }
    
    // MARK: - Uploading
    
    public func prepareAndUploadDisplayPicture(imageData: Data) -> AnyPublisher<UploadResult, DisplayPictureError> {
        return Just(())
            .setFailureType(to: DisplayPictureError.self)
            .tryMap { [weak self, dependencies] _ -> (Network.PreparedRequest<FileUploadResponse>, String, String, Data, Data) in
                // If the profile avatar was updated or removed then encrypt with a new profile key
                // to ensure that other users know that our profile picture was updated
                let newEncryptionKey: Data
                let finalImageData: Data
                let fileExtension: String
                let guessedFormat: ImageFormat = imageData.guessedImageFormat
                
                finalImageData = try {
                    switch guessedFormat {
                        case .gif, .webp:
                            // Animated images can't be resized so if the data is too large we should error
                            guard imageData.count <= DisplayPictureManager.maxBytes else {
                                // Our avatar dimensions are so small that it's incredibly unlikely we wouldn't
                                // be able to fit our profile photo (eg. generating pure noise at our resolution
                                // compresses to ~200k)
                                Log.error(.displayPictureManager, "Updating service with profile failed: \(DisplayPictureError.uploadMaxFileSizeExceeded).")
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
                        Log.verbose(.displayPictureManager, "Avatar image should have been resized before trying to upload.")
                        image = image.resized(toFillPixelSize: CGSize(width: DisplayPictureManager.maxDiameter, height: DisplayPictureManager.maxDiameter))
                    }
                    
                    guard let data: Data = image.jpegData(compressionQuality: 0.95) else {
                        Log.error(.displayPictureManager, "Updating service with profile failed.")
                        throw DisplayPictureError.writeFailed
                    }
                    
                    guard data.count <= DisplayPictureManager.maxBytes else {
                        // Our avatar dimensions are so small that it's incredibly unlikely we wouldn't
                        // be able to fit our profile photo (eg. generating pure noise at our resolution
                        // compresses to ~200k)
                        Log.verbose(.displayPictureManager, "Suprised to find profile avatar was too large. Was it scaled properly? image: \(image)")
                        Log.error(.displayPictureManager, "Updating service with profile failed.")
                        throw DisplayPictureError.uploadMaxFileSizeExceeded
                    }
                    
                    return data
                }()
                
                newEncryptionKey = try dependencies[singleton: .crypto]
                    .tryGenerate(.randomBytes(DisplayPictureManager.aes256KeyByteLength))
                fileExtension = {
                    switch guessedFormat {
                        case .gif: return "gif"     // stringlint:ignore
                        case .webp: return "webp"   // stringlint:ignore
                        default: return "jpg"       // stringlint:ignore
                    }
                }()
                
                // If we have a new avatar image, we must first:
                //
                // * Write it to disk.
                // * Encrypt it
                // * Upload it to asset service
                // * Send asset service info to Signal Service
                Log.verbose(.displayPictureManager, "Updating local profile on service with new avatar.")
                
                let fileName: String = dependencies[singleton: .crypto].generate(.uuid())
                    .defaulting(to: UUID())
                    .uuidString
                    .appendingFileExtension(fileExtension)
                
                guard let filePath: String = try? self?.filepath(for: fileName) else {
                    throw DisplayPictureError.invalidFilename
                }
                
                // Write the avatar to disk
                do { try finalImageData.write(to: URL(fileURLWithPath: filePath), options: [.atomic]) }
                catch {
                    Log.error(.displayPictureManager, "Updating service with profile failed.")
                    throw DisplayPictureError.writeFailed
                }
                
                // Encrypt the avatar for upload
                guard
                    let encryptedData: Data = dependencies[singleton: .crypto].generate(
                        .encryptedDataDisplayPicture(data: finalImageData, key: newEncryptionKey, using: dependencies)
                    )
                else {
                    Log.error(.displayPictureManager, "Updating service with profile failed.")
                    throw DisplayPictureError.encryptionFailed
                }
                
                // Upload the avatar to the FileServer
                guard
                    let preparedUpload: Network.PreparedRequest<FileUploadResponse> = try? Network.preparedUpload(
                        data: encryptedData,
                        requestAndPathBuildTimeout: Network.fileUploadTimeout,
                        using: dependencies
                    )
                else {
                    Log.error(.displayPictureManager, "Updating service with profile failed.")
                    throw DisplayPictureError.uploadFailed
                }
                
                return (preparedUpload, filePath, fileName, newEncryptionKey, finalImageData)
            }
            .flatMap { [dependencies] preparedUpload, finalFilePath, fileName, newEncryptionKey, finalImageData -> AnyPublisher<(FileUploadResponse, String, String, Data, Data), Error> in
                preparedUpload.send(using: dependencies)
                    .map { _, response -> (FileUploadResponse, String, String, Data, Data) in
                        (response, finalFilePath, fileName, newEncryptionKey, finalImageData)
                    }
                    .eraseToAnyPublisher()
            }
            .mapError { error in
                Log.error(.displayPictureManager, "Updating service with profile failed with error: \(error).")
                
                switch error {
                    case NetworkError.maxFileSizeExceeded: return DisplayPictureError.uploadMaxFileSizeExceeded
                    case let displayPictureError as DisplayPictureError: return displayPictureError
                    default: return DisplayPictureError.uploadFailed
                }
            }
            .map { [dependencies] fileUploadResponse, finalFilePath, fileName, newEncryptionKey, finalImageData -> UploadResult in
                let downloadUrl: String = Network.FileServer.downloadUrlString(for: fileUploadResponse.id)
                
                /// Load the data into the `imageDataManager` (assuming we will use it elsewhere in the UI)
                Task(priority: .userInitiated) {
                    await dependencies[singleton: .imageDataManager].load(
                        .url(URL(fileURLWithPath: finalFilePath))
                    )
                }
                
                Log.verbose(.displayPictureManager, "Successfully uploaded avatar image.")
                return (downloadUrl, fileName, newEncryptionKey)
            }
            .eraseToAnyPublisher()
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
    var downloadsToSchedule: Set<DisplayPictureManager.DownloadInfo> { get }
}

public protocol DisplayPictureCacheType: DisplayPictureImmutableCacheType, MutableCacheType {
    var downloadsToSchedule: Set<DisplayPictureManager.DownloadInfo> { get set }
}
