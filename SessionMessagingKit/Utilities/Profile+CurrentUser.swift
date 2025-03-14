// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import UIKit.UIImage
import Combine
import GRDB
import SessionUtilitiesKit

// MARK: - Log.Category

private extension Log.Category {
    static let profile: Log.Category = .create("Profile", defaultLevel: .info)
}

// MARK: - Profile Updates

public extension Profile {
    enum DisplayNameUpdate {
        case none
        case contactUpdate(String?)
        case currentUserUpdate(String?)
    }
    
    static func isTooLong(profileName: String) -> Bool {
        /// String.utf8CString will include the null terminator (Int8)0 as the end of string buffer.
        /// When the string is exactly 100 bytes String.utf8CString.count will be 101.
        /// However in LibSession, the Contact C API supports 101 characters in order to account for
        /// the null terminator - char name[101]. So it is OK to use String.utf8.count
        return (profileName.utf8CString.count > LibSession.sizeMaxNameBytes)
    }
    
    static func updateLocal(
        displayNameUpdate: DisplayNameUpdate = .none,
        displayPictureUpdate: DisplayPictureManager.Update = .none,
        using dependencies: Dependencies
    ) -> AnyPublisher<Void, DisplayPictureError> {
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        let isRemovingAvatar: Bool = {
            switch displayPictureUpdate {
                case .currentUserRemove: return true
                default: return false
            }
        }()
        
        switch displayPictureUpdate {
            case .contactRemove, .contactUpdateTo, .groupRemove, .groupUpdateTo, .groupUploadImageData:
                return Fail(error: DisplayPictureError.invalidCall)
                    .eraseToAnyPublisher()
            
            case .none, .currentUserRemove, .currentUserUpdateTo:
                return dependencies[singleton: .storage]
                    .writePublisher { db in
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
                            
                            switch existingProfileUrl {
                                case .some: Log.verbose(.profile, "Updating local profile on service with cleared avatar.")
                                case .none: Log.verbose(.profile, "Updating local profile on service with no avatar.")
                            }
                        }
                        
                        try Profile.updateIfNeeded(
                            db,
                            publicKey: userSessionId.hexString,
                            displayNameUpdate: displayNameUpdate,
                            displayPictureUpdate: displayPictureUpdate,
                            sentTimestamp: dependencies.dateNow.timeIntervalSince1970,
                            using: dependencies
                        )
                        Log.info(.profile, "Successfully updated user profile.")
                    }
                    .mapError { _ in DisplayPictureError.databaseChangesFailed }
                    .eraseToAnyPublisher()
                
            case .currentUserUploadImageData(let data):
                return dependencies[singleton: .displayPictureManager]
                    .prepareAndUploadDisplayPicture(imageData: data)
                    .mapError { $0 as Error }
                    .flatMapStorageWritePublisher(using: dependencies, updates: { db, result in
                        try Profile.updateIfNeeded(
                            db,
                            publicKey: userSessionId.hexString,
                            displayNameUpdate: displayNameUpdate,
                            displayPictureUpdate: .currentUserUpdateTo(
                                url: result.downloadUrl,
                                key: result.encryptionKey,
                                fileName: result.fileName
                            ),
                            sentTimestamp: dependencies.dateNow.timeIntervalSince1970,
                            using: dependencies
                        )
                        
                        dependencies[defaults: .standard, key: .lastProfilePictureUpload] = dependencies.dateNow
                        Log.info(.profile, "Successfully updated user profile.")
                    })
                    .mapError { error in
                        switch error {
                            case let displayPictureError as DisplayPictureError: return displayPictureError
                            default: return DisplayPictureError.databaseChangesFailed
                        }
                    }
                    .eraseToAnyPublisher()
        }
    }    
    
    static func updateIfNeeded(
        _ db: Database,
        publicKey: String,
        displayNameUpdate: DisplayNameUpdate = .none,
        displayPictureUpdate: DisplayPictureManager.Update,
        blocksCommunityMessageRequests: Bool? = nil,
        sentTimestamp: TimeInterval,
        using dependencies: Dependencies
    ) throws {
        let isCurrentUser = (publicKey == dependencies[cache: .general].sessionId.hexString)
        let profile: Profile = Profile.fetchOrCreate(db, id: publicKey)
        var profileChanges: [ConfigColumnAssignment] = []
        
        /// There were some bugs (somewhere) where some of these timestamps valid could be in seconds or milliseconds so we need to try to
        /// detect this and convert it to proper seconds (if we don't then we will never update the profile)
        func convertToSections(_ maybeValue: Double?) -> TimeInterval {
            guard let value: Double = maybeValue else { return 0 }
            
            if value > 9_000_000_000_000 {  // Microseconds
                return (value / 1_000_000)
            } else if value > 9_000_000_000 {  // Milliseconds
                return (value / 1000)
            }
            
            return TimeInterval(value)  // Seconds
        }
        
        // Name
        // FIXME: This 'lastNameUpdate' approach is buggy - we should have a timestamp on the ConvoInfoVolatile
        switch (displayNameUpdate, isCurrentUser, (sentTimestamp > convertToSections(profile.lastNameUpdate))) {
            case (.none, _, _): break
            case (.currentUserUpdate(let name), true, _), (.contactUpdate(let name), false, true):
                guard let name: String = name, !name.isEmpty, name != profile.name else { break }
                
                profileChanges.append(Profile.Columns.name.set(to: name))
                profileChanges.append(Profile.Columns.lastNameUpdate.set(to: sentTimestamp))
            
            // Don't want profiles in messages to modify the current users profile info so ignore those cases
            default: break
        }
        
        // Blocks community message requests flag
        if let blocksCommunityMessageRequests: Bool = blocksCommunityMessageRequests, sentTimestamp > convertToSections(profile.lastBlocksCommunityMessageRequests) {
            profileChanges.append(Profile.Columns.blocksCommunityMessageRequests.set(to: blocksCommunityMessageRequests))
            profileChanges.append(Profile.Columns.lastBlocksCommunityMessageRequests.set(to: sentTimestamp))
        }
        
        // Profile picture & profile key
        switch (displayPictureUpdate, isCurrentUser) {
            case (.none, _): break
            case (.currentUserUploadImageData, _), (.groupRemove, _), (.groupUpdateTo, _):
                preconditionFailure("Invalid options for this function")
                
            case (.contactRemove, false), (.currentUserRemove, true):
                profileChanges.append(Profile.Columns.profilePictureUrl.set(to: nil))
                profileChanges.append(Profile.Columns.profileEncryptionKey.set(to: nil))
                profileChanges.append(Profile.Columns.profilePictureFileName.set(to: nil))
                profileChanges.append(Profile.Columns.lastProfilePictureUpdate.set(to: sentTimestamp))
            
            case (.contactUpdateTo(let url, let key, let fileName), false),
                (.currentUserUpdateTo(let url, let key, let fileName), true):
                if url != profile.profilePictureUrl {
                    profileChanges.append(Profile.Columns.profilePictureUrl.set(to: url))
                }
                
                if key != profile.profileEncryptionKey && key.count == DisplayPictureManager.aes256KeyByteLength {
                    profileChanges.append(Profile.Columns.profileEncryptionKey.set(to: key))
                }
                
                // Profile filename (this isn't synchronized between devices)
                if let fileName: String = fileName {
                    profileChanges.append(Profile.Columns.profilePictureFileName.set(to: fileName))
                }
                
                // If we have already downloaded the image then no need to download it again
                let fileExistsAtExpectedPath: Bool = {
                    switch fileName {
                        case .some(let fileName):
                            let maybeFilePath: String? = try? dependencies[singleton: .displayPictureManager]
                                .filepath(for: fileName)
                            return maybeFilePath
                                .map { dependencies[singleton: .fileManager].fileExists(atPath: $0) }
                                .defaulting(to: false)
                            
                        case .none:
                            // If we don't have a fileName then we want to try to check if the path that
                            // would be generated for the URL exists, we don't know what the file extension
                            // should be so need to check if there is any file type with this name
                            let expectedFilename: String = dependencies[singleton: .displayPictureManager]
                                .generateFilenameWithoutExtension(for: url)
                            let displayPictureFolderPath: String = dependencies[singleton: .displayPictureManager].sharedDataDisplayPictureDirPath()
                            let filePaths: [URL] = (try? dependencies[singleton: .fileManager]
                                .contentsOfDirectory(at: URL(fileURLWithPath: displayPictureFolderPath)))
                                .defaulting(to: [])
                            
                            return filePaths.contains(where: { url -> Bool in
                                url.deletingLastPathComponent().lastPathComponent == expectedFilename
                            })
                    }
                }()
                
                if !fileExistsAtExpectedPath {
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
                        canStartJob: dependencies[singleton: .appContext].isMainApp
                    )
                }
                
                // Update the 'lastProfilePictureUpdate' timestamp for either external or local changes
                profileChanges.append(Profile.Columns.lastProfilePictureUpdate.set(to: sentTimestamp))
            
            // Don't want profiles in messages to modify the current users profile info so ignore those cases
            default: break
        }
        
        // Persist any changes
        if !profileChanges.isEmpty {
            try profile.upsert(db)
            
            try Profile
                .filter(id: publicKey)
                .updateAllAndConfig(
                    db,
                    profileChanges,
                    using: dependencies
                )
        }
    }
}
