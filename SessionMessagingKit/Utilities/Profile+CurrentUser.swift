// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
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
        
        /// Note: LibSession.sizeMaxNameBytes is 100 not 101
        return (profileName.bytes.count > LibSession.sizeMaxNameBytes)
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
                                .select(.displayPictureUrl)
                                .asRequest(of: String.self)
                                .fetchOne(db)
                            
                            /// Remove any cached avatar image data
                            if
                                let existingProfileUrl: String = existingProfileUrl,
                                let filePath: String = try? dependencies[singleton: .displayPictureManager]
                                    .path(for: existingProfileUrl)
                            {
                                Task(priority: .low) {
                                    await dependencies[singleton: .imageDataManager].removeImage(
                                        identifier: filePath
                                    )
                                    try? dependencies[singleton: .fileManager].removeItem(atPath: filePath)
                                }
                            }
                            
                            switch existingProfileUrl {
                                case .some: Log.verbose(.profile, "Updating local profile on service with cleared avatar.")
                                case .none: Log.verbose(.profile, "Updating local profile on service with no avatar.")
                            }
                        }
                        
                        let profileUpdateTimestampMs: Double = dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
                        try Profile.updateIfNeeded(
                            db,
                            publicKey: userSessionId.hexString,
                            displayNameUpdate: displayNameUpdate,
                            displayPictureUpdate: displayPictureUpdate,
                            profileUpdateTimestamp: TimeInterval(profileUpdateTimestampMs / 1000),
                            isReuploadingCurrentUserProfilePicture: false,
                            using: dependencies
                        )
                        Log.info(.profile, "Successfully updated user profile.")
                    }
                    .mapError { _ in DisplayPictureError.databaseChangesFailed }
                    .eraseToAnyPublisher()
                
            case .currentUserUploadImageData(let data, let isReupload):
                return dependencies[singleton: .displayPictureManager]
                    .prepareAndUploadDisplayPicture(imageData: data)
                    .mapError { $0 as Error }
                    .flatMapStorageWritePublisher(using: dependencies, updates: { db, result in
                        let profileUpdateTimestampMs: Double = dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
                        try Profile.updateIfNeeded(
                            db,
                            publicKey: userSessionId.hexString,
                            displayNameUpdate: displayNameUpdate,
                            displayPictureUpdate: .currentUserUpdateTo(
                                url: result.downloadUrl,
                                key: result.encryptionKey,
                                filePath: result.filePath,
                                sessionProProof: dependencies.mutate(cache: .libSession) { $0.getCurrentUserProProof() }
                            ),
                            profileUpdateTimestamp: TimeInterval(profileUpdateTimestampMs / 1000),
                            isReuploadingCurrentUserProfilePicture: isReupload,
                            using: dependencies
                        )
                        
                        dependencies[defaults: .standard, key: .profilePictureExpiresDate] = result.expries
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
        _ db: ObservingDatabase,
        publicKey: String,
        displayNameUpdate: DisplayNameUpdate = .none,
        displayPictureUpdate: DisplayPictureManager.Update,
        blocksCommunityMessageRequests: Bool? = nil,
        profileUpdateTimestamp: TimeInterval,
        isReuploadingCurrentUserProfilePicture: Bool = false,
        using dependencies: Dependencies
    ) throws {
        let isCurrentUser = (publicKey == dependencies[cache: .general].sessionId.hexString)
        let profile: Profile = Profile.fetchOrCreate(db, id: publicKey)
        var profileChanges: [ConfigColumnAssignment] = []
        
        guard profileUpdateTimestamp > profile.profileLastUpdated.defaulting(to: 0) else { return }
        
        // Name
        switch (displayNameUpdate, isCurrentUser) {
            case (.none, _): break
            case (.currentUserUpdate(let name), true), (.contactUpdate(let name), false):
                guard let name: String = name, !name.isEmpty, name != profile.name else { break }
                
                if profile.name != name {
                    profileChanges.append(Profile.Columns.name.set(to: name))
                    db.addProfileEvent(id: publicKey, change: .name(name))
                }
            
            // Don't want profiles in messages to modify the current users profile info so ignore those cases
            default: break
        }
        
        // Blocks community message requests flag
        if let blocksCommunityMessageRequests: Bool = blocksCommunityMessageRequests {
            profileChanges.append(Profile.Columns.blocksCommunityMessageRequests.set(to: blocksCommunityMessageRequests))
        }
        
        // Profile picture & profile key
        switch (displayPictureUpdate, isCurrentUser) {
            case (.none, _): break
            case (.currentUserUploadImageData, _), (.groupRemove, _), (.groupUpdateTo, _):
                preconditionFailure("Invalid options for this function")
                
            case (.contactRemove, false), (.currentUserRemove, true):
                if profile.displayPictureEncryptionKey != nil {
                    profileChanges.append(Profile.Columns.displayPictureEncryptionKey.set(to: nil))
                }
                
                if profile.displayPictureUrl != nil {
                    profileChanges.append(Profile.Columns.displayPictureUrl.set(to: nil))
                    db.addProfileEvent(id: publicKey, change: .displayPictureUrl(nil))
                }
            
            case (.contactUpdateTo(let url, let key, let filePath, let proProof), false),
                (.currentUserUpdateTo(let url, let key, let filePath, let proProof), true):
                /// If we have already downloaded the image then no need to download it again (the database records will be updated
                /// once the download completes)
                if !dependencies[singleton: .fileManager].fileExists(atPath: filePath) {
                    dependencies[singleton: .jobRunner].add(
                        db,
                        job: Job(
                            variant: .displayPictureDownload,
                            shouldBeUnique: true,
                            details: DisplayPictureDownloadJob.Details(
                                target: .profile(id: profile.id, url: url, encryptionKey: key),
                                timestamp: profileUpdateTimestamp
                            )
                        ),
                        canStartJob: dependencies[singleton: .appContext].isMainApp
                    )
                }
                else {
                    if url != profile.displayPictureUrl {
                        profileChanges.append(Profile.Columns.displayPictureUrl.set(to: url))
                        db.addProfileEvent(id: publicKey, change: .displayPictureUrl(url))
                    }
                    
                    if key != profile.displayPictureEncryptionKey && key.count == DisplayPictureManager.aes256KeyByteLength {
                        profileChanges.append(Profile.Columns.displayPictureEncryptionKey.set(to: key))
                    }
                }
            
            // TODO: Handle Pro Proof update
            
            /// Don't want profiles in messages to modify the current users profile info so ignore those cases
            default: break
        }
        
        // Persist any changes
        if !profileChanges.isEmpty || isReuploadingCurrentUserProfilePicture {
            profileChanges.append(Profile.Columns.profileLastUpdated.set(to: profileUpdateTimestamp))
            
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
