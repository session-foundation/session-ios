// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import CryptoKit
import Combine
import GRDB
import SessionUtilitiesKit

public struct ProfileManager {
    public enum DisplayNameUpdate {
        case none
        case contactUpdate(String?)
        case currentUserUpdate(String?)
    }
    
    public enum DisplayPictureUpdate {
        case none
        
        case contactRemove
        case contactUpdateTo(url: String, key: Data, fileName: String?)
        
        case currentUserRemove
        case currentUserUploadImageData(Data)
        case currentUserUpdateTo(url: String, key: Data, fileName: String?)
    }
    
    // The max bytes for a user's profile name, encoded in UTF8.
    // Before encrypting and submitting we NULL pad the name data to this length.
    public static let maxAvatarDiameter: CGFloat = 640
    private static let maxAvatarBytes: UInt = (5 * 1000 * 1000)
    public static let avatarAES256KeyByteLength: Int = 32
    private static let avatarNonceLength: Int = 12
    private static let avatarTagLength: Int = 16
    
    @ThreadSafeObject private static var profileAvatarCache: [String: Data] = [:]
    @ThreadSafeObject private static var currentAvatarDownloads: Set<String> = []
    
    // MARK: - Functions
    
    public static func isTooLong(profileName: String) -> Bool {
        ///String.utf8CString will include the null terminator (Int8)0 as the end of string buffer.
        ///When the string is exactly 100 bytes String.utf8CString.count will be 101.
        ///However in LibSession, the Contact C API supports 101 characters in order to account for
        ///the null terminator - char name[101]. So it is OK to use String.utf8.count
        return (profileName.utf8.count > LibSession.libSessionMaxNameByteLength)
    }
    
    public static func isTooLong(profileUrl: String) -> Bool {
        return (profileUrl.utf8CString.count > LibSession.libSessionMaxProfileUrlByteLength)
    }
    
    public static func profileAvatar(_ db: Database? = nil, id: String) -> Data? {
        guard let db: Database = db else {
            return Storage.shared.read { db in profileAvatar(db, id: id) }
        }
        guard let profile: Profile = try? Profile.fetchOne(db, id: id) else { return nil }
        
        return profileAvatar(profile: profile)
    }
    
    public static func profileAvatar(profile: Profile) -> Data? {
        if let profileFileName: String = profile.profilePictureFileName, !profileFileName.isEmpty {
            return loadProfileAvatar(for: profileFileName, profile: profile)
        }
        
        if let profilePictureUrl: String = profile.profilePictureUrl, !profilePictureUrl.isEmpty {
            // FIXME: Refactor avatar downloading to be a proper Job so we can avoid this
            JobRunner.afterBlockingQueue {
                ProfileManager.downloadAvatar(for: profile)
            }
        }
        
        return nil
    }
    
    private static func loadProfileAvatar(for fileName: String, profile: Profile) -> Data? {
        if let cachedImageData: Data = profileAvatarCache[fileName] {
            return cachedImageData
        }
        
        guard
            !fileName.isEmpty,
            let data: Data = loadProfileData(with: fileName),
            data.isValidImage
        else {
            // If we can't load the avatar or it's an invalid/corrupted image then clear out
            // the 'profilePictureFileName' and try to re-download
            Storage.shared.writeAsync(
                updates: { db in
                    _ = try? Profile
                        .filter(id: profile.id)
                        .updateAll(db, Profile.Columns.profilePictureFileName.set(to: nil))
                },
                completion: { _ in
                    // Try to re-download the avatar if it has a URL
                    if let profilePictureUrl: String = profile.profilePictureUrl, !profilePictureUrl.isEmpty {
                        // FIXME: Refactor avatar downloading to be a proper Job so we can avoid this
                        JobRunner.afterBlockingQueue {
                            ProfileManager.downloadAvatar(for: profile)
                        }
                    }
                }
            )
            return nil
        }
    
        _profileAvatarCache.performUpdate { $0.setting(fileName, data) }
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
    
    // MARK: - Profile Encryption
    
    private static func encryptData(data: Data, key: Data) -> Data? {
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
    
    private static func decryptData(data: Data, key: Data) -> Data? {
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
    
    // stringlint:ignore_contents
    public static let sharedDataProfileAvatarsDirPath: String = {
        let path: String = URL(fileURLWithPath: FileManager.default.appSharedDataDirectoryPath)
            .appendingPathComponent("ProfileAvatars")
            .path
        try? FileSystem.ensureDirectoryExists(at: path)
        
        return path
    }()
    
    private static let profileAvatarsDirPath: String = {
        let path: String = ProfileManager.sharedDataProfileAvatarsDirPath
        try? FileSystem.ensureDirectoryExists(at: path)
        
        return path
    }()
    
    public static func profileAvatarFilepath(_ db: Database? = nil, id: String) -> String? {
        guard let db: Database = db else {
            return Storage.shared.read { db in profileAvatarFilepath(db, id: id) }
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
    
    // MARK: - Other Users' Profiles
    
    public static func downloadAvatar(for profile: Profile, funcName: String = #function) {
        guard !currentAvatarDownloads.contains(profile.id) else {
            // Download already in flight; ignore
            return
        }
        guard
            let profileUrlStringAtStart: String = profile.profilePictureUrl,
            let profileUrl: URL = URL(string: profileUrlStringAtStart)
        else { return SNLog("Skipping downloading avatar for \(profile.id) because url is not set") }
        guard
            let profileKeyAtStart: Data = profile.profileEncryptionKey,
            profileKeyAtStart.count > 0
        else { return }
        
        let fileName: String = UUID().uuidString.appendingFileExtension("jpg")  // stringlint:ignore
        let filePath: String = ProfileManager.profileAvatarFilepath(filename: fileName)
        var backgroundTask: SessionBackgroundTask? = SessionBackgroundTask(label: #function)
        
        Log.verbose("downloading profile avatar: \(profile.id)")
        _currentAvatarDownloads.performUpdate { $0.inserting(profile.id) }
        
        LibSession
            .downloadFile(from: .fileServer(downloadUrl: profileUrl))
            .subscribe(on: DispatchQueue.global(qos: .background))
            .receive(on: DispatchQueue.global(qos: .background))
            .sinkUntilComplete(
                receiveCompletion: { _ in
                    _currentAvatarDownloads.performUpdate { $0.removing(profile.id) }
                    
                    // Redundant but without reading 'backgroundTask' it will warn that the variable
                    // isn't used
                    if backgroundTask != nil { backgroundTask = nil }
                },
                receiveValue: { _, data in
                    guard let latestProfile: Profile = Storage.shared.read({ db in try Profile.fetchOne(db, id: profile.id) }) else {
                        return
                    }
                    
                    guard
                        let latestProfileKey: Data = latestProfile.profileEncryptionKey,
                        !latestProfileKey.isEmpty,
                        latestProfileKey == profileKeyAtStart
                    else {
                        Log.warn("Ignoring avatar download for obsolete user profile.")
                        return
                    }
                    
                    guard profileUrlStringAtStart == latestProfile.profilePictureUrl else {
                        Log.warn("Avatar url has changed during download.")
                        
                        if latestProfile.profilePictureUrl?.isEmpty == false {
                            self.downloadAvatar(for: latestProfile)
                        }
                        return
                    }
                    
                    guard let decryptedData: Data = decryptData(data: data, key: profileKeyAtStart) else {
                        Log.warn("Avatar data for \(profile.id) could not be decrypted.")
                        return
                    }
                    
                    try? decryptedData.write(to: URL(fileURLWithPath: filePath), options: [.atomic])
                    
                    guard UIImage(contentsOfFile: filePath) != nil else {
                        Log.warn("Avatar image for \(profile.id) could not be loaded.")
                        return
                    }
                    
                    // Update the cache first (in case the DBWrite thread is blocked, this way other threads
                    // can retrieve from the cache and avoid triggering a download)
                    _profileAvatarCache.performUpdate { $0.setting(fileName, decryptedData) }
                    
                    // Store the updated 'profilePictureFileName'
                    Storage.shared.write { db in
                        _ = try? Profile
                            .filter(id: profile.id)
                            .updateAll(db, Profile.Columns.profilePictureFileName.set(to: fileName))
                    }
                }
            )
    }
    
    // MARK: - Current User Profile
    
    public static func updateLocal(
        queue: DispatchQueue,
        displayNameUpdate: DisplayNameUpdate = .none,
        displayPictureUpdate: DisplayPictureUpdate = .none,
        success: ((Database) throws -> ())? = nil,
        failure: ((ProfileManagerError) -> ())? = nil,
        using dependencies: Dependencies = Dependencies()
    ) {
        let userPublicKey: String = getUserHexEncodedPublicKey(using: dependencies)
        let isRemovingDisplayPicture: Bool = {
            switch displayPictureUpdate {
                case .currentUserRemove: return true
                default: return false
            }
        }()
        
        switch displayPictureUpdate {
            case .contactRemove, .contactUpdateTo:
                failure?(ProfileManagerError.invalidCall)
            
            case .none, .currentUserRemove, .currentUserUpdateTo:
                dependencies.storage.writeAsync { db in
                    if isRemovingDisplayPicture {
                        let existingProfileUrl: String? = try Profile
                            .filter(id: userPublicKey)
                            .select(.profilePictureUrl)
                            .asRequest(of: String.self)
                            .fetchOne(db)
                        let existingProfileFileName: String? = try Profile
                            .filter(id: userPublicKey)
                            .select(.profilePictureFileName)
                            .asRequest(of: String.self)
                            .fetchOne(db)
                        
                        // Remove any cached avatar image value
                        if let fileName: String = existingProfileFileName {
                            _profileAvatarCache.performUpdate { $0.removingValue(forKey: fileName) }
                        }
                        
                        // stringlint:ignore_start
                        Log.debug(existingProfileUrl != nil ?
                            "Updating local profile on service with cleared avatar." :
                            "Updating local profile on service with no avatar."
                        )
                        // stringlint:ignore_stop
                    }
                    
                    try ProfileManager.updateProfileIfNeeded(
                        db,
                        publicKey: userPublicKey,
                        displayNameUpdate: displayNameUpdate,
                        displayPictureUpdate: displayPictureUpdate,
                        sentTimestamp: dependencies.dateNow.timeIntervalSince1970,
                        using: dependencies
                    )
                    
                    SNLog("Successfully updated service with profile.")
                    try success?(db)
                }
                
            case .currentUserUploadImageData(let data):
                prepareAndUploadAvatarImage(
                    queue: queue,
                    imageData: data,
                    success: { downloadUrl, fileName, newProfileKey in
                        Storage.shared.writeAsync { db in
                            try ProfileManager.updateProfileIfNeeded(
                                db,
                                publicKey: userPublicKey,
                                displayNameUpdate: displayNameUpdate,
                                displayPictureUpdate: .currentUserUpdateTo(url: downloadUrl, key: newProfileKey, fileName: fileName),
                                sentTimestamp: dependencies.dateNow.timeIntervalSince1970,
                                using: dependencies
                            )
                                
                            SNLog("Successfully updated service with profile.")
                            try success?(db)
                        }
                    },
                    failure: failure
                )
        }
    }
    
    private static func prepareAndUploadAvatarImage(
        queue: DispatchQueue,
        imageData: Data,
        success: @escaping ((downloadUrl: String, fileName: String, profileKey: Data)) -> (),
        failure: ((ProfileManagerError) -> ())? = nil
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
                        image = image.resized(toFillPixelSize: CGSize(width: maxAvatarDiameter, height: maxAvatarDiameter))
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
                // stringlint:ignore_contents
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
            Log.debug("Updating local profile on service with new avatar.")
            
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
            LibSession
                .uploadToServer(encryptedAvatarData, to: .fileServer, fileName: nil)
                .tryMap { _, fileUploadResponse in try Network.fileServerDownloadUrlFor(fileId: fileUploadResponse.id) }
                .subscribe(on: DispatchQueue.global(qos: .userInitiated))
                .receive(on: queue)
                .sinkUntilComplete(
                    receiveCompletion: { result in
                        switch result {
                            case .finished: break
                            case .failure(let error):
                                SNLog("Updating service with profile failed.")
                                
                                let isMaxFileSizeExceeded: Bool = ((error as? NetworkError) == .maxFileSizeExceeded)
                                failure?(isMaxFileSizeExceeded ?
                                    .avatarUploadMaxFileSizeExceeded :
                                    .avatarUploadFailed
                                )
                        }
                    },
                    receiveValue: { downloadUrl in
                        // Update the cached avatar image value
                        _profileAvatarCache.performUpdate { $0.setting(fileName, avatarImageData) }
                        UserDefaults.standard[.lastProfilePictureUpload] = Date()
                        
                        SNLog("Successfully uploaded avatar image.")
                        success((downloadUrl.absoluteString, fileName, newProfileKey))
                    }
                )
        }
    }
    
    public static func updateProfileIfNeeded(
        _ db: Database,
        publicKey: String,
        displayNameUpdate: DisplayNameUpdate = .none,
        displayPictureUpdate: DisplayPictureUpdate,
        blocksCommunityMessageRequests: Bool? = nil,
        sentTimestamp: TimeInterval,
        using dependencies: Dependencies
    ) throws {
        let isCurrentUser = (publicKey == getUserHexEncodedPublicKey(db, using: dependencies))
        let profile: Profile = Profile.fetchOrCreate(db, id: publicKey)
        var profileChanges: [ConfigColumnAssignment] = []
        
        // Name
        // FIXME: This 'lastNameUpdate' approach is buggy - we should have a timestamp on the ConvoInfoVolatile
        switch (displayNameUpdate, isCurrentUser, (sentTimestamp > (profile.lastNameUpdate ?? 0))) {
            case (.none, _, _): break
            case (.currentUserUpdate(let name), true, _), (.contactUpdate(let name), false, true):
                guard let name: String = name, !name.isEmpty, name != profile.name else { break }
                
                profileChanges.append(Profile.Columns.name.set(to: name))
                profileChanges.append(Profile.Columns.lastNameUpdate.set(to: sentTimestamp))
            
            // Don't want profiles in messages to modify the current users profile info so ignore those cases
            default: break
        }
        
        // Blocks community message requets flag (only update for other users)
        if !isCurrentUser, let blocksCommunityMessageRequests: Bool = blocksCommunityMessageRequests, sentTimestamp > (profile.lastBlocksCommunityMessageRequests ?? 0) {
            profileChanges.append(Profile.Columns.blocksCommunityMessageRequests.set(to: blocksCommunityMessageRequests))
            profileChanges.append(Profile.Columns.lastBlocksCommunityMessageRequests.set(to: sentTimestamp))
        }
        
        // Profile picture & profile key
        var avatarNeedsDownload: Bool = false
        var targetAvatarUrl: String? = nil
        
        switch (displayPictureUpdate, isCurrentUser) {
            case (.none, _): break
            case (.currentUserUploadImageData, _): preconditionFailure("Invalid options for this function")
                
            case (.contactRemove, false), (.currentUserRemove, true):
                profileChanges.append(Profile.Columns.profilePictureUrl.set(to: nil))
                profileChanges.append(Profile.Columns.profileEncryptionKey.set(to: nil))
                profileChanges.append(Profile.Columns.profilePictureFileName.set(to: nil))
                profileChanges.append(Profile.Columns.lastProfilePictureUpdate.set(to: sentTimestamp))
            
            case (.contactUpdateTo(let url, let key, let fileName), false),
                (.currentUserUpdateTo(let url, let key, let fileName), true):
                if url != profile.profilePictureUrl {
                    profileChanges.append(Profile.Columns.profilePictureUrl.set(to: url))
                    avatarNeedsDownload = true
                    targetAvatarUrl = url
                }
                
                if key != profile.profileEncryptionKey && key.count == ProfileManager.avatarAES256KeyByteLength {
                    profileChanges.append(Profile.Columns.profileEncryptionKey.set(to: key))
                }
                
                // Profile filename (this isn't synchronized between devices)
                if let fileName: String = fileName {
                    profileChanges.append(Profile.Columns.profilePictureFileName.set(to: fileName))
                    
                    // If we have already downloaded the image then no need to download it again
                    avatarNeedsDownload = (
                        avatarNeedsDownload &&
                        !ProfileManager.hasProfileImageData(with: fileName)
                    )
                }
                
                // Update the 'lastProfilePictureUpdate' timestamp for either external or local changes
                profileChanges.append(Profile.Columns.lastProfilePictureUpdate.set(to: sentTimestamp))
            
            // Don't want profiles in messages to modify the current users profile info so ignore those cases
            default: break
        }
        
        // Persist any changes
        if !profileChanges.isEmpty {
            try profile.save(db)
            try Profile
                .filter(id: publicKey)
                .updateAllAndConfig(db, profileChanges, using: dependencies)
        }
        
        // Download the profile picture if needed
        // FIXME: We don't want to trigger the download within the notification extension, as part of the groups rebuild this has been moved into a Job which won't be run so this logic can be removed
        guard avatarNeedsDownload && Singleton.hasAppContext && Singleton.appContext.isMainApp else { return }
        
        let dedupeIdentifier: String = "AvatarDownload-\(publicKey)-\(targetAvatarUrl ?? "remove")" // stringlint:ignore
        
        db.afterNextTransactionNestedOnce(dedupeId: dedupeIdentifier) { db in
            // Need to refetch to ensure the db changes have occurred
            let targetProfile: Profile = Profile.fetchOrCreate(db, id: publicKey)
            
            // FIXME: Refactor avatar downloading to be a proper Job so we can avoid this
            dependencies.jobRunner.afterBlockingQueue {
                ProfileManager.downloadAvatar(for: targetProfile)
            }
        }
    }
}
