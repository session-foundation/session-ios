// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import CryptoKit
import Combine
import GRDB
import SignalCoreKit
import SessionSnodeKit
import SessionUtilitiesKit

public struct ProfileManager {
    public enum AvatarUpdate {
        case none
        case remove
        case uploadImageData(Data)
        case updateTo(url: String, key: Data, fileName: String?)
    }
    
    private struct DownloadInfo: Hashable {
        let profile: Profile
        let currentFileInvalid: Bool
    }
    
    // The max bytes for a user's profile name, encoded in UTF8.
    // Before encrypting and submitting we NULL pad the name data to this length.
    public static let maxAvatarDiameter: CGFloat = 640
    private static let maxAvatarBytes: UInt = (5 * 1000 * 1000)
    public static let avatarAES256KeyByteLength: Int = 32
    private static let avatarNonceLength: Int = 12
    private static let avatarTagLength: Int = 16
    
    private static var profileAvatarCache: Atomic<[String: Data]> = Atomic([:])
    
    private static var downloadsToSchedule: Atomic<Set<DownloadInfo>> = Atomic([])
    private static var scheduleDownloadsPublisher: AnyPublisher<Void, Never>?
    private static let scheduleDownloadsTrigger: PassthroughSubject<(), Never> = PassthroughSubject()
    
    // MARK: - Functions
    
    public static func isToLong(profileName: String) -> Bool {
        return (profileName.utf8CString.count > SessionUtil.libSessionMaxNameByteLength)
    }
    
    public static func isToLong(profileUrl: String) -> Bool {
        return (profileUrl.utf8CString.count > SessionUtil.libSessionMaxProfileUrlByteLength)
    }
    
    public static func profileAvatar(
        _ db: Database? = nil,
        id: String,
        using dependencies: Dependencies = Dependencies()
    ) -> Data? {
        guard let db: Database = db else {
            return dependencies[singleton: .storage].read { db in profileAvatar(db, id: id) }
        }
        guard let profile: Profile = try? Profile.fetchOne(db, id: id) else { return nil }
        
        return profileAvatar(profile: profile)
    }
    
    @discardableResult public static func profileAvatar(
        profile: Profile,
        using dependencies: Dependencies = Dependencies()
    ) -> Data? {
        if let profileFileName: String = profile.profilePictureFileName, !profileFileName.isEmpty {
            return loadProfileAvatar(for: profileFileName, profile: profile, using: dependencies)
        }
        
        if let profilePictureUrl: String = profile.profilePictureUrl, !profilePictureUrl.isEmpty {
            scheduleDownload(for: profile, currentFileInvalid: false, using: dependencies)
        }
        
        return nil
    }
    
    private static func loadProfileAvatar(
        for fileName: String,
        profile: Profile,
        using dependencies: Dependencies
    ) -> Data? {
        if let cachedImageData: Data = profileAvatarCache.wrappedValue[fileName] {
            return cachedImageData
        }
        
        guard
            !fileName.isEmpty,
            let data: Data = loadProfileData(with: fileName),
            data.isValidImage
        else {
            // If we can't load the avatar or it's an invalid/corrupted image then clear it out and re-download
            scheduleDownload(for: profile, currentFileInvalid: true, using: dependencies)
            return nil
        }
    
        profileAvatarCache.mutate { $0[fileName] = data }
        return data
    }
    
    public static func hasProfileImageData(with fileName: String?) -> Bool {
        guard let fileName: String = fileName, !fileName.isEmpty else { return false }
        
        return FileManager.default
            .fileExists(atPath: ProfileManager.profileAvatarFilepath(filename: fileName))
    }
    
    public static func loadProfileData(with fileName: String) -> Data? {
        let filePath: String = ProfileManager.profileAvatarFilepath(filename: fileName)
        
        return try? Data(contentsOf: URL(fileURLWithPath: filePath))
    }
    
    public static func cache(fileName: String, avatarData: Data) {
        profileAvatarCache.mutate { $0[fileName] = avatarData }
    }
    
    private static func scheduleDownload(
        for profile: Profile,
        currentFileInvalid invalid: Bool,
        using dependencies: Dependencies
    ) {
        downloadsToSchedule.mutate { $0 = $0.inserting(DownloadInfo(profile: profile, currentFileInvalid: invalid)) }
        
        /// This method can be triggered very frequently when processing messages so we want to throttle the updates to 250ms (it's for starting
        /// avatar downloads so that should definitely be fast enough)
        if scheduleDownloadsPublisher == nil {
            scheduleDownloadsPublisher = scheduleDownloadsTrigger
                .throttle(for: .milliseconds(250), scheduler: DispatchQueue.global(qos: .userInitiated), latest: true)
                .handleEvents(
                    receiveOutput: { _ in
                        let pendingInfo: Set<DownloadInfo> = downloadsToSchedule.mutate {
                            let result: Set<DownloadInfo> = $0
                            $0.removeAll()
                            return result
                        }
                        
                        dependencies[singleton: .storage].writeAsync(using: dependencies) { db in
                            pendingInfo.forEach { info in
                                // If the current file is invalid then clear out the 'profilePictureFileName'
                                // and try to re-download the file
                                if info.currentFileInvalid {
                                    _ = try? Profile
                                        .filter(id: profile.id)
                                        .updateAll(db, Profile.Columns.profilePictureFileName.set(to: nil))
                                }
                                
                                dependencies[singleton: .jobRunner].add(
                                    db,
                                    job: Job(
                                        variant: .displayPictureDownload,
                                        shouldBeUnique: true,
                                        details: DisplayPictureDownloadJob.Details(profile: info.profile)
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
            key.count == ProfileManager.avatarAES256KeyByteLength,
            let nonceData: Data = try? Randomness.generateRandomBytes(numberBytes: ProfileManager.avatarNonceLength),
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
        guard key.count == ProfileManager.avatarAES256KeyByteLength else { return nil }
        
        // The key structure is: nonce || ciphertext || authTag
        let cipherTextLength: Int = (data.count - (ProfileManager.avatarNonceLength + ProfileManager.avatarTagLength))
        
        guard
            cipherTextLength > 0,
            let sealedData: AES.GCM.SealedBox = try? AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: data.subdata(in: 0..<ProfileManager.avatarNonceLength)),
                ciphertext: data.subdata(in: ProfileManager.avatarNonceLength..<(ProfileManager.avatarNonceLength + cipherTextLength)),
                tag: data.subdata(in: (data.count - ProfileManager.avatarTagLength)..<data.count)
            ),
            let decryptedData: Data = try? AES.GCM.open(sealedData, using: SymmetricKey(data: key))
        else { return nil }
        
        return decryptedData
    }
    
    // MARK: - File Paths
    
    public static let sharedDataProfileAvatarsDirPath: String = {
        let path: String = URL(fileURLWithPath: OWSFileSystem.appSharedDataDirectoryPath())
            .appendingPathComponent("ProfileAvatars")
            .path
        OWSFileSystem.ensureDirectoryExists(path)
        
        return path
    }()
    
    private static let profileAvatarsDirPath: String = {
        let path: String = ProfileManager.sharedDataProfileAvatarsDirPath
        OWSFileSystem.ensureDirectoryExists(path)
        
        return path
    }()
    
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
        
        return maybeFileName.map { ProfileManager.profileAvatarFilepath(filename: $0) }
    }
    
    public static func profileAvatarFilepath(filename: String) -> String {
        guard !filename.isEmpty else { return "" }
        
        return URL(fileURLWithPath: sharedDataProfileAvatarsDirPath)
            .appendingPathComponent(filename)
            .path
    }
    
    public static func resetProfileStorage() {
        try? FileManager.default.removeItem(atPath: ProfileManager.profileAvatarsDirPath)
    }
    
    // MARK: - Current User Profile
    
    public static func updateLocal(
        queue: DispatchQueue,
        profileName: String,
        avatarUpdate: AvatarUpdate = .none,
        success: ((Database) throws -> ())? = nil,
        failure: ((ProfileManagerError) -> ())? = nil,
        using dependencies: Dependencies = Dependencies()
    ) {
        let userSessionId: SessionId = getUserSessionId(using: dependencies)
        let isRemovingAvatar: Bool = {
            switch avatarUpdate {
                case .remove: return true
                default: return false
            }
        }()
        
        switch avatarUpdate {
            case .none, .remove, .updateTo:
                dependencies[singleton: .storage].writeAsync { db in
                    if isRemovingAvatar {
                        let existingProfileUrl: String? = try Profile
                            .filter(id: userSessionId.hexString)
                            .select(.profilePictureUrl)
                            .asRequest(of: String.self)
                            .fetchOne(db)
                        let existingProfileFileName: String? = try Profile
                            .filter(id: userSessionId.hexString)
                            .select(.profilePictureFileName)
                            .asRequest(of: String.self)
                            .fetchOne(db)
                        
                        // Remove any cached avatar image value
                        if let fileName: String = existingProfileFileName {
                            profileAvatarCache.mutate { $0[fileName] = nil }
                        }
                        
                        OWSLogger.verbose(existingProfileUrl != nil ?
                            "Updating local profile on service with cleared avatar." :
                            "Updating local profile on service with no avatar."
                        )
                    }
                    
                    try ProfileManager.updateProfileIfNeeded(
                        db,
                        publicKey: userSessionId.hexString,
                        name: profileName,
                        avatarUpdate: avatarUpdate,
                        sentTimestamp: dependencies.dateNow.timeIntervalSince1970,
                        using: dependencies
                    )
                    
                    SNLog("Successfully updated service with profile.")
                    try success?(db)
                }
                
            case .uploadImageData(let data):
                prepareAndUploadAvatarImage(
                    queue: queue,
                    imageData: data,
                    success: { downloadUrl, fileName, newProfileKey in
                        dependencies[singleton: .storage].writeAsync { db in
                            try ProfileManager.updateProfileIfNeeded(
                                db,
                                publicKey: userSessionId.hexString,
                                name: profileName,
                                avatarUpdate: .updateTo(url: downloadUrl, key: newProfileKey, fileName: fileName),
                                sentTimestamp: dependencies.dateNow.timeIntervalSince1970,
                                using: dependencies
                            )
                                
                            SNLog("Successfully updated service with profile.")
                            try success?(db)
                        }
                    },
                    failure: failure,
                    using: dependencies
                )
        }
    }
    
    private static func prepareAndUploadAvatarImage(
        queue: DispatchQueue,
        imageData: Data,
        success: @escaping ((downloadUrl: String, fileName: String, profileKey: Data)) -> (),
        failure: ((ProfileManagerError) -> ())? = nil,
        using dependencies: Dependencies
    ) {
        queue.async {
            // If the profile avatar was updated or removed then encrypt with a new profile key
            // to ensure that other users know that our profile picture was updated
            let newProfileKey: Data
            let avatarImageData: Data
            let fileExtension: String
            
            do {
                let guessedFormat: ImageFormat = imageData.guessedImageFormat
                
                avatarImageData = try {
                    switch guessedFormat {
                        case .gif, .webp:
                            // Animated images can't be resized so if the data is too large we should error
                            guard imageData.count <= maxAvatarBytes else {
                                // Our avatar dimensions are so small that it's incredibly unlikely we wouldn't
                                // be able to fit our profile photo (eg. generating pure noise at our resolution
                                // compresses to ~200k)
                                SNLog("Animated profile avatar was too large.")
                                SNLog("Updating service with profile failed.")
                                throw ProfileManagerError.avatarUploadMaxFileSizeExceeded
                            }
                            
                            return imageData
                            
                        default: break
                    }
                    
                    // Process the image to ensure it meets our standards for size and compress it to
                    // standardise the formwat and remove any metadata
                    guard var image: UIImage = UIImage(data: imageData) else { throw ProfileManagerError.invalidCall }
                    
                    if image.size.width != maxAvatarDiameter || image.size.height != maxAvatarDiameter {
                        // To help ensure the user is being shown the same cropping of their avatar as
                        // everyone else will see, we want to be sure that the image was resized before this point.
                        SNLog("Avatar image should have been resized before trying to upload")
                        image = image.resizedImage(toFillPixelSize: CGSize(width: maxAvatarDiameter, height: maxAvatarDiameter))
                    }
                    
                    guard let data: Data = image.jpegData(compressionQuality: 0.95) else {
                        SNLog("Updating service with profile failed.")
                        throw ProfileManagerError.avatarWriteFailed
                    }
                    
                    guard data.count <= maxAvatarBytes else {
                        // Our avatar dimensions are so small that it's incredibly unlikely we wouldn't
                        // be able to fit our profile photo (eg. generating pure noise at our resolution
                        // compresses to ~200k)
                        SNLog("Suprised to find profile avatar was too large. Was it scaled properly? image: \(image)")
                        SNLog("Updating service with profile failed.")
                        throw ProfileManagerError.avatarUploadMaxFileSizeExceeded
                    }
                    
                    return data
                }()
                
                newProfileKey = try Randomness.generateRandomBytes(numberBytes: ProfileManager.avatarAES256KeyByteLength)
                fileExtension = {
                    switch guessedFormat {
                        case .gif: return "gif"
                        case .webp: return "webp"
                        default: return "jpg"
                    }
                }()
            }
            // TODO: Test that this actually works
            catch let error as ProfileManagerError { return (failure?(error) ?? {}()) }
            catch { return (failure?(ProfileManagerError.invalidCall) ?? {}()) }

            // If we have a new avatar image, we must first:
            //
            // * Write it to disk.
            // * Encrypt it
            // * Upload it to asset service
            // * Send asset service info to Signal Service
            OWSLogger.verbose("Updating local profile on service with new avatar.")
            
            let fileName: String = UUID().uuidString.appendingFileExtension(fileExtension)
            let filePath: String = ProfileManager.profileAvatarFilepath(filename: fileName)
            
            // Write the avatar to disk
            do { try avatarImageData.write(to: URL(fileURLWithPath: filePath), options: [.atomic]) }
            catch {
                SNLog("Updating service with profile failed.")
                failure?(.avatarWriteFailed)
                return
            }
            
            // Encrypt the avatar for upload
            guard let encryptedAvatarData: Data = encryptData(data: avatarImageData, key: newProfileKey) else {
                SNLog("Updating service with profile failed.")
                failure?(.avatarEncryptionFailed)
                return
            }
            
            // Upload the avatar to the FileServer
            guard let preparedUpload: HTTP.PreparedRequest<FileUploadResponse> = try? FileServerAPI.preparedUpload(encryptedAvatarData, using: dependencies) else {
                SNLog("Updating service with profile failed.")
                failure?(.avatarUploadFailed)
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
                                failure?(isMaxFileSizeExceeded ?
                                    .avatarUploadMaxFileSizeExceeded :
                                    .avatarUploadFailed
                                )
                        }
                    },
                    receiveValue: { _, fileUploadResponse in
                        let downloadUrl: String = "\(FileServerAPI.server)/file/\(fileUploadResponse.id)"
                        
                        // Update the cached avatar image value
                        profileAvatarCache.mutate { $0[fileName] = avatarImageData }
                        dependencies[defaults: .standard, key: .lastProfilePictureUpload] = dependencies.dateNow
                        
                        SNLog("Successfully uploaded avatar image.")
                        success((downloadUrl, fileName, newProfileKey))
                    }
                )
        }
    }
    
    public static func updateProfileIfNeeded(
        _ db: Database,
        publicKey: String,
        name: String?,
        blocksCommunityMessageRequests: Bool? = nil,
        avatarUpdate: AvatarUpdate,
        sentTimestamp: TimeInterval,
        calledFromConfigHandling: Bool = false,
        using dependencies: Dependencies
    ) throws {
        let isCurrentUser = (publicKey == getUserSessionId(db, using: dependencies).hexString)
        let profile: Profile = Profile.fetchOrCreate(db, id: publicKey)
        var profileChanges: [ConfigColumnAssignment] = []
        
        // Name
        if let name: String = name, !name.isEmpty, name != profile.name {
            if sentTimestamp > (profile.lastNameUpdate ?? 0) || (isCurrentUser && calledFromConfigHandling) {
                profileChanges.append(Profile.Columns.name.set(to: name))
                profileChanges.append(Profile.Columns.lastNameUpdate.set(to: sentTimestamp))
            }
        }
        
        // Blocks community message requests flag
        if let blocksCommunityMessageRequests: Bool = blocksCommunityMessageRequests, sentTimestamp > (profile.lastBlocksCommunityMessageRequests ?? 0) {
            profileChanges.append(Profile.Columns.blocksCommunityMessageRequests.set(to: blocksCommunityMessageRequests))
            profileChanges.append(Profile.Columns.lastBlocksCommunityMessageRequests.set(to: sentTimestamp))
        }
        
        // Profile picture & profile key
        if sentTimestamp > (profile.lastProfilePictureUpdate ?? 0) || (isCurrentUser && calledFromConfigHandling) {
            switch avatarUpdate {
                case .none: break
                case .uploadImageData: preconditionFailure("Invalid options for this function")
                    
                case .remove:
                    profileChanges.append(Profile.Columns.profilePictureUrl.set(to: nil))
                    profileChanges.append(Profile.Columns.profileEncryptionKey.set(to: nil))
                    profileChanges.append(Profile.Columns.profilePictureFileName.set(to: nil))
                    profileChanges.append(Profile.Columns.lastProfilePictureUpdate.set(to: sentTimestamp))
                    
                case .updateTo(let url, let key, .some(let fileName)) where ProfileManager.hasProfileImageData(with: fileName):
                    // Update the 'lastProfilePictureUpdate' timestamp for either external or local changes
                    profileChanges.append(Profile.Columns.profilePictureFileName.set(to: fileName))
                    profileChanges.append(Profile.Columns.lastProfilePictureUpdate.set(to: sentTimestamp))
                    
                    if url != profile.profilePictureUrl {
                        profileChanges.append(Profile.Columns.profilePictureUrl.set(to: url))
                    }
                    
                    if key != profile.profileEncryptionKey && key.count == ProfileManager.avatarAES256KeyByteLength {
                        profileChanges.append(Profile.Columns.profileEncryptionKey.set(to: key))
                    }
                    
                case .updateTo(let url, let key, _):
                    dependencies[singleton: .jobRunner].add(
                        db,
                        job: Job(
                            variant: .displayPictureDownload,
                            shouldBeUnique: true,
                            details: DisplayPictureDownloadJob.Details(
                                target: .profile(id: profile.id, url: url, encryptionKey: key),
                                timestamp: sentTimestamp
                            )
                        ),
                        canStartJob: true,
                        using: dependencies
                    )
            }
        }
        
        // Persist any changes
        if !profileChanges.isEmpty {
            try profile.save(db)
            
            try Profile
                .filter(id: publicKey)
                .updateAllAndConfig(
                    db,
                    profileChanges,
                    calledFromConfig: calledFromConfigHandling,
                    using: dependencies
                )
        }
    }
}
