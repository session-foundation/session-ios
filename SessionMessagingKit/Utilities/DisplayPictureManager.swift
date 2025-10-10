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
        case groupUploadImage(source: ImageDataManager.DataSource, cropRect: CGRect?)
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
    public static var encryptionKeySize: Int { LibSession.attachmentEncryptionKeySize }
    internal static let nonceLength: Int = 12
    internal static let tagLength: Int = 16
    
    private let dependencies: Dependencies
    private let cache: StringCache = StringCache(
        totalCostLimit: 5 * 1024 * 1024 /// Max 5MB of url to hash data (approx. 20,000 records)
    )
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
        else { throw AttachmentError.invalidPath }
        
        /// If the provided url is located in the temporary directory then it _is_ a valid path, so we should just return it directly instead
        /// of generating a hash
        guard !dependencies[singleton: .fileManager].isLocatedInTemporaryDirectory(urlString) else {
            return urlString
        }
        
        /// Otherwise we need to generate the deterministic file path based on the url provided
        ///
        /// **Note:** Now that download urls could contain fragments (or query params I guess) that could result in inconsistent paths
        /// with old attachments so just to be safe we should strip them before generating the `urlHash`
        let urlNoQueryOrFragment: String = urlString
            .components(separatedBy: "?")[0]
            .components(separatedBy: "#")[0]
        let urlHash = try {
            guard let cachedHash: String = cache.object(forKey: urlNoQueryOrFragment) else {
                return try dependencies[singleton: .crypto]
                    .tryGenerate(.hash(message: Array(urlNoQueryOrFragment.utf8)))
                    .toHexString()
            }
            
            return cachedHash
        }()
        
        return URL(fileURLWithPath: sharedDataDisplayPictureDirPath())
            .appendingPathComponent(urlHash)
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
    
    private static func standardOperations(cropRect: CGRect?) -> Set<PendingAttachment.Operation> {
        return [
            .convert(to: .webPLossy(
                maxDimension: DisplayPictureManager.maxDimension,
                cropRect: cropRect
            )),
            .stripImageMetadata
        ]
    }
    
    public func reuploadNeedsPreparation(attachment: PendingAttachment) -> Bool {
        /// When re-uploading we only want to check if the file needs to be resized or converted to `WebP` to avoid a situation where
        /// different clients end up "ping-ponging" changes to the display picture
        return attachment.needsPreparation(
            operations: [
                .convert(to: .webPLossy(maxDimension: DisplayPictureManager.maxDimension))
            ]
        )
    }
    
    public func prepareDisplayPicture(
        attachment: PendingAttachment,
        fallbackIfConversionTakesTooLong: Bool = false,
        cropRect: CGRect? = nil
    ) async throws -> PreparedAttachment {
        /// If we don't want the fallbacks then just run the standard operations
        guard fallbackIfConversionTakesTooLong else {
            return try await attachment.prepare(
                operations: DisplayPictureManager.standardOperations(cropRect: cropRect),
                using: dependencies
            )
        }
        
        /// The desired output for a profile picture is a `WebP` at the specified size (and `cropRect`) that is generated in under `5s`
        do {
            let result: PreparedAttachment = try await withThrowingTaskGroup { [dependencies] group in
                group.addTask {
                    return try await attachment.prepare(
                        operations: DisplayPictureManager.standardOperations(cropRect: cropRect),
                        using: dependencies
                    )
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(5))
                    throw AttachmentError.conversionTimeout
                }
                defer { group.cancelAll() }
                
                return try await group.first(where: { _ in true }) ?? {
                    throw AttachmentError.couldNotConvert
                }()
            }
            let preparedSize: UInt64? = dependencies[singleton: .fileManager].fileSize(of: result.filePath)
            
            guard (preparedSize ?? UInt64.max) < attachment.fileSize else {
                throw AttachmentError.conversionResultedInLargerFile
            }
            
            return result
        }
        catch AttachmentError.conversionTimeout {}              /// Expected case
        catch AttachmentError.conversionResultedInLargerFile {} /// Expected case
        catch { throw error }
        
        /// If the original file was a `GIF` then we should see if we can just resize/crop that instead, but since we've already waited
        /// for `5s` we only want to give `2s` for this conversion
        ///
        /// **Note:** In this case we want to ignore any error and just fallback to the original file (with metadata stripped)
        if attachment.utType == .gif {
            let maybeResult: PreparedAttachment? = try? await withThrowingTaskGroup { [dependencies] group in
                group.addTask {
                    return try await attachment.prepare(
                        operations: [
                            .convert(to: .gif(
                                maxDimension: DisplayPictureManager.maxDimension,
                                cropRect: cropRect
                            )),
                            .stripImageMetadata
                        ],
                        using: dependencies
                    )
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(2))
                    throw AttachmentError.conversionTimeout
                }
                defer { group.cancelAll() }
                
                return try await group.first(where: { _ in true }) ?? {
                    throw AttachmentError.couldNotConvert
                }()
            }
            
            /// Only return the resized GIF if it's smaller than the original (the current GIF encoding we use is just the built-in iOS
            /// encoding which isn't very advanced, as such some GIFs can end up quite large, even if they are cropped versions
            /// of other GIFs - this is likely due to the lack of "frame differencing" support)
            if
                let result: PreparedAttachment = maybeResult,
                let preparedSize: UInt64 = dependencies[singleton: .fileManager]
                    .fileSize(of: result.filePath),
                preparedSize < attachment.fileSize
            {
                return result
            }
        }
        
        /// If we weren't able to generate the `WebP` (or resized `GIF` if the source was a `GIF`) then just use the original source
        /// with metadata stripped
        return try await attachment.prepare(
            operations: [.stripImageMetadata],
            using: dependencies
        )
    }
    
    public func uploadDisplayPicture(preparedAttachment: PreparedAttachment) async throws -> UploadResult {
        let uploadResponse: FileUploadResponse
        let pendingAttachment: PendingAttachment = try PendingAttachment(
            attachment: preparedAttachment.attachment,
            using: dependencies
        )
        let attachment: PreparedAttachment = try await pendingAttachment.prepare(
            operations: [
                .encrypt(domain: .profilePicture)
            ],
            using: dependencies
        )
        
        /// Clean up the file after the upload completes
        defer {
            try? dependencies[singleton: .fileManager].removeItem(atPath: attachment.filePath)
        }
        
        /// Ensure we have an encryption key for the `PreparedAttachment` we want to use as a display picture
        guard let encryptionKey: Data = attachment.attachment.encryptionKey else {
            throw AttachmentError.notEncrypted
        }
        
        do {
            /// Upload the data
            let data: Data = try dependencies[singleton: .fileManager]
                .contents(atPath: attachment.filePath) ?? { throw AttachmentError.invalidData }()
            let request: Network.PreparedRequest<FileUploadResponse> = try Network.FileServer.preparedUpload(
                data: data,
                requestAndPathBuildTimeout: Network.fileUploadTimeout,
                using: dependencies
            )
            
            // TODO: Refactor to use async/await when the networking refactor is merged
            uploadResponse = try await request
                .send(using: dependencies)
                .values
                .first(where: { _ in true })?.1 ?? { throw AttachmentError.uploadFailed }()
        }
        catch NetworkError.maxFileSizeExceeded { throw AttachmentError.fileSizeTooLarge }
        catch { throw AttachmentError.uploadFailed }
        
        /// Generate the `downloadUrl` and move the temporary file to it's expected destination
        ///
        /// **Note:** Display pictures are currently stored unencrypted so we need to move the original `preparedAttachment`
        /// file to the `finalFilePath` rather than the encrypted one
        // FIXME: Should probably store display pictures encrypted and decrypt on load
        let downloadUrl: String = Network.FileServer.downloadUrlString(
            for: uploadResponse.id,
            using: dependencies
        )
        let finalFilePath: String = try dependencies[singleton: .displayPictureManager].path(for: downloadUrl)
        try dependencies[singleton: .fileManager].moveItem(
            atPath: preparedAttachment.filePath,
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
