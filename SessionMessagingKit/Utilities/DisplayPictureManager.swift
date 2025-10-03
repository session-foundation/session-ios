// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import UIKit
import Combine
import GRDB
import SessionUIKit
import SessionNetworkingKit
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
    public typealias UploadResult = (downloadUrl: String, filePath: String, encryptionKey: Data)
    
    public enum Update {
        case none
        
        case contactRemove
        case contactUpdateTo(url: String, key: Data)
        
        case currentUserRemove
        case currentUserUpdateTo(url: String, key: Data, isReupload: Bool)
        
        case groupRemove
        case groupUploadImage(ImageDataManager.DataSource)
        case groupUpdateTo(url: String, key: Data)
        
        static func from(_ profile: VisibleMessage.VMProfile, fallback: Update, using dependencies: Dependencies) -> Update {
            return from(profile.profilePictureUrl, key: profile.profileKey, fallback: fallback, using: dependencies)
        }
        
        public static func from(_ profile: Profile, fallback: Update, using dependencies: Dependencies) -> Update {
            return from(profile.displayPictureUrl, key: profile.displayPictureEncryptionKey, fallback: fallback, using: dependencies)
        }
        
        static func from(_ url: String?, key: Data?, fallback: Update, using dependencies: Dependencies) -> Update {
            guard
                let url: String = url,
                let key: Data = key
            else { return fallback }
            
            return .contactUpdateTo(url: url, key: key)
        }
    }
    
    public static let maxBytes: UInt = (5 * 1000 * 1000)
    public static let maxDimension: CGFloat = 600
    public static let aes256KeyByteLength: Int = 32
    internal static let nonceLength: Int = 12
    internal static let tagLength: Int = 16
    
    private let dependencies: Dependencies
    private let scheduleDownloads: PassthroughSubject<(), Never> = PassthroughSubject()
    private var scheduleDownloadsCancellable: AnyCancellable?
    
    /// `NSCache` has more nuanced memory management systems than just listening for `didReceiveMemoryWarningNotification`
    /// and can clear out values gradually, it can also remove items based on their "cost" so is better suited than our custom `LRUCache`
    ///
    /// Additionally `NSCache` is thread safe so we don't need to do any custom `ThreadSafeObject` work to interact with it
    private var cache: NSCache<NSString, NSString> = {
        let result: NSCache<NSString, NSString> = NSCache()
        result.totalCostLimit = 5 * 1024 * 1024 /// Max 5MB of url to hash data (approx. 20,000 records)
        
        return result
    }()
    
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
            .appendingPathComponent("DisplayPictures")
            .path
        try? dependencies[singleton: .fileManager].ensureDirectoryExists(at: path)
        
        return path
    }
    
    // MARK: - File Paths
    
    /// **Note:** Generally the url we get won't have an extension and we don't want to make assumptions until we have the actual
    /// image data so generate a name for the file and then determine the extension separately
    public func path(for urlString: String?) throws -> String {
        guard
            let urlString: String = urlString,
            !urlString.isEmpty
        else { throw DisplayPictureError.invalidCall }
        
        let urlHash = try {
            guard let cachedHash: String = cache.object(forKey: urlString as NSString) as? String else {
                return try dependencies[singleton: .crypto]
                    .tryGenerate(.hash(message: Array(urlString.utf8)))
                    .toHexString()
            }
            
            return cachedHash
        }()
        
        return URL(fileURLWithPath: sharedDataDisplayPictureDirPath())
            .appendingPathComponent(urlHash)
            .path
    }
    
    public func path(for source: ImageDataManager.DataSource) throws -> String {
        switch source {
            case .url(let url): return try path(for: url.absoluteString)
            default: throw DisplayPictureError.invalidCall
        }
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
                    let pendingInfo: Set<Owner> = dependencies.mutate(cache: .displayPicture) { cache in
                        let result: Set<Owner> = cache.downloadsToSchedule
                        cache.downloadsToSchedule.removeAll()
                        return result
                    }
                    
                    dependencies[singleton: .storage].writeAsync { db in
                        pendingInfo.forEach { owner in
                            dependencies[singleton: .jobRunner].add(
                                db,
                                job: Job(
                                    variant: .displayPictureDownload,
                                    shouldBeUnique: true,
                                    details: DisplayPictureDownloadJob.Details(owner: owner)
                                ),
                                canStartJob: true
                            )
                        }
                    }
                }
            )
    }
    
    public func scheduleDownload(for owner: Owner) {
        guard owner.canDownloadImage else { return }
        
        dependencies.mutate(cache: .displayPicture) { cache in
            cache.downloadsToSchedule.insert(owner)
        }
        scheduleDownloads.send(())
    }
    
    // MARK: - Uploading
    
    public func prepareDisplayPicture(
        attachment: PendingAttachment,
        transformations: Set<PendingAttachment.Transform>? = nil
    ) throws -> PreparedAttachment {
        /// If we weren't given custom transformations then use the default ones for display pictures
        let finalTransfomations: Set<PendingAttachment.Transform> = (
            transformations ??
            [
                .compress,
                .convertToStandardFormats,
                .resize(maxDimension: DisplayPictureManager.maxDimension),
                .stripImageMetadata,
                .encrypt(legacy: true)  // FIXME: Remove the `legacy` encryption option
            ]
        )
        
        return try attachment.prepare(transformations: finalTransfomations, using: dependencies)
    }
    
    public func uploadDisplayPicture(attachment: PreparedAttachment) async throws -> UploadResult {
        let uploadResponse: FileUploadResponse
        
        /// Ensure we have an encryption key for the `PreparedAttachment` we want to use as a display picture
        guard let encryptionKey: Data = attachment.attachment.encryptionKey else {
            throw DisplayPictureError.notEncrypted
        }
        
        do {
            /// Upload the data
            let data: Data = try dependencies[singleton: .fileManager]
                .contents(atPath: attachment.temporaryFilePath) ?? { throw AttachmentError.invalidData }()
            let request: Network.PreparedRequest<FileUploadResponse> = try Network.preparedUpload(
                data: data,
                requestAndPathBuildTimeout: Network.fileUploadTimeout,
                using: dependencies
            )
            
            // TODO: Refactor to use async/await when the networking refactor is merged
            uploadResponse = try await request
                .send(using: dependencies)
                .values
                .first(where: { _ in true })?.1 ?? { throw DisplayPictureError.uploadFailed }()
        }
        catch NetworkError.maxFileSizeExceeded { throw DisplayPictureError.uploadMaxFileSizeExceeded }
        catch { throw DisplayPictureError.uploadFailed }
        
        /// Generate the `downloadUrl` and move the temporary file to it's expected destination
        let downloadUrl: String = Network.FileServer.downloadUrlString(for: uploadResponse.id)
        let finalFilePath: String = try dependencies[singleton: .displayPictureManager].path(for: downloadUrl)
        try dependencies[singleton: .fileManager].moveItem(
            atPath: attachment.temporaryFilePath,
            toPath: finalFilePath
        )
        
        /// Load the data into the `imageDataManager` (assuming we will use it elsewhere in the UI)
        Task.detached(priority: .userInitiated) { [imageDataManager = dependencies[singleton: .imageDataManager]] in
            await imageDataManager.load(.url(URL(fileURLWithPath: finalFilePath)))
        }
        
        return (downloadUrl, finalFilePath, encryptionKey)
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
        
        var canDownloadImage: Bool {
            switch self {
                case .user(let profile): return (profile.displayPictureUrl?.isEmpty == false)
                case .group(let group): return (group.displayPictureUrl?.isEmpty == false)
                case .community(let openGroup): return (openGroup.imageId?.isEmpty == false)
                case .file: return false
            }
        }
    }
}

// MARK: - DisplayPicture Cache

public extension DisplayPictureManager {
    class Cache: DisplayPictureCacheType {
        public var downloadsToSchedule: Set<DisplayPictureManager.Owner> = []
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
    var downloadsToSchedule: Set<DisplayPictureManager.Owner> { get }
}

public protocol DisplayPictureCacheType: DisplayPictureImmutableCacheType, MutableCacheType {
    var downloadsToSchedule: Set<DisplayPictureManager.Owner> { get set }
}
