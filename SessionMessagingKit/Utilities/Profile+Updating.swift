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
    ) async throws {
        /// Perform any non-database related changes for the update
        switch displayPictureUpdate {
            case .contactRemove, .contactUpdateTo, .groupRemove, .groupUpdateTo, .groupUploadImage:
                throw AttachmentError.invalidStartState
            
            case .none, .currentUserUpdateTo: break
            case .currentUserRemove:
                /// Remove any cached avatar image data
                if
                    let existingProfileUrl: String = dependencies
                        .mutate(cache: .libSession, { $0.profile })
                        .displayPictureUrl,
                    let filePath: String = try? dependencies[singleton: .displayPictureManager]
                        .path(for: existingProfileUrl)
                {
                    Log.verbose(.profile, "Updating local profile on service with cleared avatar.")
                    Task(priority: .low) {
                        await dependencies[singleton: .imageDataManager].removeImage(
                            identifier: filePath
                        )
                        try? dependencies[singleton: .fileManager].removeItem(atPath: filePath)
                    }
                }
                else {
                    Log.verbose(.profile, "Updating local profile on service with no avatar.")
                }
        }
        
        /// Finally, update the `Profile` data in the database
        do {
            let userSessionId: SessionId = dependencies[cache: .general].sessionId
            let profileUpdateTimestamp: TimeInterval = (dependencies[cache: .snodeAPI].currentOffsetTimestampMs() / 1000)
            
            try await dependencies[singleton: .storage].writeAsync { db in
                try Profile.updateIfNeeded(
                    db,
                    publicKey: userSessionId.hexString,
                    displayNameUpdate: displayNameUpdate,
                    displayPictureUpdate: displayPictureUpdate,
                    profileUpdateTimestamp: profileUpdateTimestamp,
                    using: dependencies
                )
            }
            Log.info(.profile, "Successfully updated user profile.")
        }
        catch { throw AttachmentError.databaseChangesFailed }
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
        suppressUserProfileConfigUpdate: Bool = false,
        using dependencies: Dependencies
    ) throws {
        let isCurrentUser = (publicKey == dependencies[cache: .general].sessionId.hexString)
        let profile: Profile = (isCurrentUser ?
            dependencies.mutate(cache: .libSession) { $0.profile } :
            Profile.fetchOrCreate(db, id: publicKey)
        )
        var updatedProfile: Profile = profile
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
                    updatedProfile = updatedProfile.with(name: name)
                    profileChanges.append(Profile.Columns.name.set(to: name))
                    db.addProfileEvent(id: publicKey, change: .name(name))
                }
            
            // Don't want profiles in messages to modify the current users profile info so ignore those cases
            default: break
        }
        
        // Blocks community message requests flag
        if let blocksCommunityMessageRequests: Bool = blocksCommunityMessageRequests {
            updatedProfile = updatedProfile.with(blocksCommunityMessageRequests: .set(to: blocksCommunityMessageRequests))
            profileChanges.append(Profile.Columns.blocksCommunityMessageRequests.set(to: blocksCommunityMessageRequests))
        }
        
        // Profile picture & profile key
        switch (displayPictureUpdate, isCurrentUser) {
            case (.none, _): break
            case (.groupRemove, _), (.groupUpdateTo, _): throw AttachmentError.invalidStartState
            case (.contactRemove, false), (.currentUserRemove, true):
                if profile.displayPictureEncryptionKey != nil {
                    updatedProfile = updatedProfile.with(displayPictureEncryptionKey: .set(to: nil))
                    profileChanges.append(Profile.Columns.displayPictureEncryptionKey.set(to: nil))
                }
                
                if profile.displayPictureUrl != nil {
                    updatedProfile = updatedProfile.with(displayPictureUrl: .set(to: nil))
                    profileChanges.append(Profile.Columns.displayPictureUrl.set(to: nil))
                    db.addProfileEvent(id: publicKey, change: .displayPictureUrl(nil))
                }
            
            case (.contactUpdateTo(let url, let key), false),
                (.currentUserUpdateTo(let url, let key, _), true):
                /// If we have already downloaded the image then no need to download it again (the database records will be updated
                /// once the download completes)
                let fileExists: Bool = ((try? dependencies[singleton: .displayPictureManager]
                    .path(for: url))
                    .map { dependencies[singleton: .fileManager].fileExists(atPath: $0) } ?? false)
                
                if !fileExists {
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
                        updatedProfile = updatedProfile.with(displayPictureUrl: .set(to: url))
                        profileChanges.append(Profile.Columns.displayPictureUrl.set(to: url))
                        db.addProfileEvent(id: publicKey, change: .displayPictureUrl(url))
                    }
                    
                    if key != profile.displayPictureEncryptionKey && key.count == DisplayPictureManager.encryptionKeySize {
                        updatedProfile = updatedProfile.with(displayPictureEncryptionKey: .set(to: key))
                        profileChanges.append(Profile.Columns.displayPictureEncryptionKey.set(to: key))
                    }
                }
            
            /// Don't want profiles in messages to modify the current users profile info so ignore those cases
            default: break
        }
        
        /// Persist any changes
        if !profileChanges.isEmpty {
            updatedProfile = updatedProfile.with(profileLastUpdated: .set(to: profileUpdateTimestamp))
            profileChanges.append(Profile.Columns.profileLastUpdated.set(to: profileUpdateTimestamp))
            
            /// The current users profile is sourced from `libSession` everywhere so no need to update the database
            if !isCurrentUser {
                try updatedProfile.upsert(db)
                
                try Profile
                    .filter(id: publicKey)
                    .updateAllAndConfig(
                        db,
                        profileChanges,
                        using: dependencies
                    )
            }
            
            /// We don't automatically update the current users profile data when changed in the database so need to manually
            /// trigger the update
            if !suppressUserProfileConfigUpdate, isCurrentUser {
                try dependencies.mutate(cache: .libSession) { cache in
                    try cache.performAndPushChange(db, for: .userProfile, sessionId: dependencies[cache: .general].sessionId) { _ in
                        try cache.updateProfile(
                            displayName: updatedProfile.name,
                            displayPictureUrl: updatedProfile.displayPictureUrl,
                            displayPictureEncryptionKey: updatedProfile.displayPictureEncryptionKey,
                            isReuploadProfilePicture: {
                                switch displayPictureUpdate {
                                    case .currentUserUpdateTo(_, _, let isReupload): return isReupload
                                    default: return false
                                }
                            }()
                        )
                    }
                }
            }
        }
    }
}
