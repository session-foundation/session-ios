// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import UIKit.UIImage
import GRDB
import SessionUtilitiesKit

// MARK: - Current User Profile

public extension Profile {
    static func isToLong(profileName: String) -> Bool {
        return (profileName.utf8CString.count > SessionUtil.sizeMaxNameBytes)
    }
    
    static func updateLocal(
        queue: DispatchQueue,
        profileName: String,
        displayPictureUpdate: DisplayPictureManager.Update = .none,
        success: ((Database) throws -> ())? = nil,
        failure: ((DisplayPictureError) -> ())? = nil,
        using dependencies: Dependencies = Dependencies()
    ) {
        let userSessionId: SessionId = getUserSessionId(using: dependencies)
        let isRemovingAvatar: Bool = {
            switch displayPictureUpdate {
                case .remove: return true
                default: return false
            }
        }()
        
        switch displayPictureUpdate {
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
                            dependencies.mutate(cache: .displayPicture) { $0.imageData[fileName] = nil }
                        }
                        
                        SNLog(.verbose, existingProfileUrl != nil ?
                            "Updating local profile on service with cleared avatar." :
                            "Updating local profile on service with no avatar."
                        )
                    }
                    
                    try Profile.updateIfNeeded(
                        db,
                        publicKey: userSessionId.hexString,
                        name: profileName,
                        displayPictureUpdate: displayPictureUpdate,
                        sentTimestamp: dependencies.dateNow.timeIntervalSince1970,
                        using: dependencies
                    )
                    
                    SNLog("Successfully updated service with profile.")
                    try success?(db)
                }
                
            case .uploadImageData(let data):
                prepareAndUploadDisplayPicture(
                    queue: queue,
                    imageData: data,
                    success: { downloadUrl, fileName, newProfileKey in
                        dependencies[singleton: .storage].writeAsync { db in
                            try Profile.updateIfNeeded(
                                db,
                                publicKey: userSessionId.hexString,
                                name: profileName,
                                displayPictureUpdate: .updateTo(url: downloadUrl, key: newProfileKey, fileName: fileName),
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
    
    private static func prepareAndUploadDisplayPicture(
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
                        case .gif: return "gif"
                        case .webp: return "webp"
                        default: return "jpg"
                    }
                }()
            }
            // TODO: Test that this actually works
            catch let error as DisplayPictureError { return (failure?(error) ?? {}()) }
            catch {
                return (failure?(DisplayPictureError.invalidCall) ?? {}())
            }

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
                        dependencies[defaults: .standard, key: .lastProfilePictureUpload] = dependencies.dateNow
                        
                        SNLog("Successfully uploaded avatar image.")
                        success((downloadUrl, fileName, newProfileKey))
                    }
                )
        }
    }
    
    static func updateIfNeeded(
        _ db: Database,
        publicKey: String,
        name: String?,
        blocksCommunityMessageRequests: Bool? = nil,
        displayPictureUpdate: DisplayPictureManager.Update,
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
            switch displayPictureUpdate {
                case .none: break
                case .uploadImageData: preconditionFailure("Invalid options for this function")
                    
                case .remove:
                    profileChanges.append(Profile.Columns.profilePictureUrl.set(to: nil))
                    profileChanges.append(Profile.Columns.profileEncryptionKey.set(to: nil))
                    profileChanges.append(Profile.Columns.profilePictureFileName.set(to: nil))
                    profileChanges.append(Profile.Columns.lastProfilePictureUpdate.set(to: sentTimestamp))
                    
                case .updateTo(let url, let key, .some(let fileName)) where FileManager.default.fileExists(atPath: DisplayPictureManager.filepath(for: fileName)):
                    // Update the 'lastProfilePictureUpdate' timestamp for either external or local changes
                    profileChanges.append(Profile.Columns.profilePictureFileName.set(to: fileName))
                    profileChanges.append(Profile.Columns.lastProfilePictureUpdate.set(to: sentTimestamp))
                    
                    if url != profile.profilePictureUrl {
                        profileChanges.append(Profile.Columns.profilePictureUrl.set(to: url))
                    }
                    
                    if key != profile.profileEncryptionKey && key.count == DisplayPictureManager.aes256KeyByteLength {
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
                    calledFromConfigHandling: calledFromConfigHandling,
                    using: dependencies
                )
        }
    }
}
