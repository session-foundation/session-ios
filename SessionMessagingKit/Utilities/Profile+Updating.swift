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
                            using: dependencies
                        )
                        Log.info(.profile, "Successfully updated user profile.")
                    }
                    .mapError { _ in DisplayPictureError.databaseChangesFailed }
                    .eraseToAnyPublisher()
                
            case .currentUserUploadImageData(let data, let isReupload):
                return dependencies[singleton: .displayPictureManager]
                    .prepareAndUploadDisplayPicture(imageData: data, compression: !isReupload)
                    .mapError { $0 as Error }
                    .flatMapStorageWritePublisher(using: dependencies, updates: { db, result in
                        let profileUpdateTimestamp: TimeInterval = dependencies[cache: .snodeAPI].currentOffsetTimestampMs() / 1000
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
                            profileUpdateTimestamp: profileUpdateTimestamp,
                            isReuploadCurrentUserProfilePicture: isReupload,
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
    
    /// To try to maintain backwards compatibility with profile changes we want to continue to accept profile changes from old clients if
    /// we haven't received a profile update from a new client yet otherwise, if we have, then we should only accept profile changes if
    /// they are newer that our cached version of the profile data
    static func shouldUpdateProfile(
        _ profileUpdateTimestamp: TimeInterval?,
        profile: Profile,
        using dependencies: Dependencies
    ) -> Bool {
        /// We should consider `libSession` the source-of-truth for profile data for contacts so try to retrieve the profile data from
        /// there before falling back to the one fetched from the database
        let targetProfile: Profile = (
            dependencies.mutate(cache: .libSession) { $0.profile(contactId: profile.id) } ??
            profile
        )
        let finalProfileUpdateTimestamp: TimeInterval = (profileUpdateTimestamp ?? 0)
        let finalCachedProfileUpdateTimestamp: TimeInterval = (targetProfile.profileLastUpdated ?? 0)
        
        /// If neither the profile update or the cached profile have a timestamp then we should just always accept the update
        ///
        /// **Note:** We check if they are equal to `0` here because the default value from `libSession` will be `0`
        /// rather than `null`
        guard finalProfileUpdateTimestamp != 0 || finalCachedProfileUpdateTimestamp != 0 else {
            return true
        }
        
        /// Otherwise we should only accept the update if it's newer than our cached value
        return (finalProfileUpdateTimestamp > finalCachedProfileUpdateTimestamp)
    }
    
    static func updateIfNeeded(
        _ db: ObservingDatabase,
        publicKey: String,
        displayNameUpdate: DisplayNameUpdate = .none,
        displayPictureUpdate: DisplayPictureManager.Update,
        blocksCommunityMessageRequests: Bool? = nil,
        profileUpdateTimestamp: TimeInterval?,
        isReuploadCurrentUserProfilePicture: Bool = false,
        using dependencies: Dependencies
    ) throws {
        let isCurrentUser = (publicKey == dependencies[cache: .general].sessionId.hexString)
        let profile: Profile = Profile.fetchOrCreate(db, id: publicKey)
        var profileChanges: [ConfigColumnAssignment] = []
        
        guard shouldUpdateProfile(profileUpdateTimestamp, profile: profile, using: dependencies) else {
            return
        }
        
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
        
        /// Persist any changes
        if !profileChanges.isEmpty {
            profileChanges.append(Profile.Columns.profileLastUpdated.set(to: profileUpdateTimestamp))
            
            try profile.upsert(db)
            
            try Profile
                .filter(id: publicKey)
                .updateAllAndConfig(
                    db,
                    profileChanges,
                    using: dependencies
                )
                
            /// We don't automatically update the current users profile data when changed in the database so need to manually
            /// trigger the update
            if isCurrentUser, let updatedProfile = try? Profile.fetchOne(db, id: publicKey) {
                try dependencies.mutate(cache: .libSession) { cache in
                    try cache.performAndPushChange(db, for: .userProfile, sessionId: dependencies[cache: .general].sessionId) { _ in
                        try cache.updateProfile(
                            displayName: updatedProfile.name,
                            displayPictureUrl: updatedProfile.displayPictureUrl,
                            displayPictureEncryptionKey: updatedProfile.displayPictureEncryptionKey,
                            isReuploadProfilePicture: isReuploadCurrentUserProfilePicture
                        )
                    }
                }
            }
        }
    }
}
