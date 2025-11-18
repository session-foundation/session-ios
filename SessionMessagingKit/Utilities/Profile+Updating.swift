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
    enum TargetUserUpdate<T> {
        case none
        case contactUpdate(T)
        case currentUserUpdate(T)
    }
    
    indirect enum CacheSource {
        case value(Profile?, fallback: CacheSource)
        case libSession(fallback: CacheSource)
        case database
        
        func resolve(_ db: ObservingDatabase, publicKey: String, using dependencies: Dependencies) -> Profile {
            switch self {
                case .value(.some(let profile), _): return profile
                case .value(.none, let fallback):
                    return fallback.resolve(db, publicKey: publicKey, using: dependencies)
                    
                case .libSession(let fallback):
                    if let profile: Profile = dependencies.mutate(cache: .libSession, { $0.profile(contactId: publicKey) }) {
                        return profile
                    }
                    
                    return fallback.resolve(db, publicKey: publicKey, using: dependencies)
                    
                case .database: return Profile.fetchOrCreate(db, id: publicKey)
            }
        }
    }
    
    enum UpdateStatus {
        case shouldUpdate
        case matchesCurrent
        case stale
        
        /// To try to maintain backwards compatibility with profile changes we want to continue to accept profile changes from old clients if
        /// we haven't received a profile update from a new client yet otherwise, if we have, then we should only accept profile changes if
        /// they are newer that our cached version of the profile data
        init(updateTimestamp: TimeInterval?, cachedProfile: Profile) {
            let finalProfileUpdateTimestamp: TimeInterval = (updateTimestamp ?? 0)
            let finalCachedProfileUpdateTimestamp: TimeInterval = (cachedProfile.profileLastUpdated ?? 0)
            
            /// If neither the profile update or the cached profile have a timestamp then we should just always accept the update
            ///
            /// **Note:** We check if they are equal to `0` here because the default value from `libSession` will be `0`
            /// rather than `null`
            guard finalProfileUpdateTimestamp != 0 || finalCachedProfileUpdateTimestamp != 0 else {
                self = .shouldUpdate
                return
            }
            
            /// Otherwise we compare the values to determine the current state
            switch finalProfileUpdateTimestamp {
                case finalCachedProfileUpdateTimestamp...:
                    self = (finalProfileUpdateTimestamp == finalCachedProfileUpdateTimestamp ?
                        .matchesCurrent :
                        .shouldUpdate
                    )
                
                default: self = .stale
            }
        }
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
        displayNameUpdate: TargetUserUpdate<String?> = .none,
        displayPictureUpdate: DisplayPictureManager.Update = .none,
        proUpdate: TargetUserUpdate<SessionPro.DecodedProForMessage?> = .none,
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
                    proUpdate: proUpdate,
                    profileUpdateTimestamp: profileUpdateTimestamp,
                    currentUserSessionIds: [userSessionId.hexString],
                    using: dependencies
                )
            }
        }
        catch { throw AttachmentError.databaseChangesFailed }
    }
    
    static func updateIfNeeded(
        _ db: ObservingDatabase,
        publicKey: String,
        displayNameUpdate: TargetUserUpdate<String?> = .none,
        displayPictureUpdate: DisplayPictureManager.Update = .none,
        nicknameUpdate: Update<String?> = .useExisting,
        blocksCommunityMessageRequests: Update<Bool?> = .useExisting,
        proUpdate: TargetUserUpdate<SessionPro.DecodedProForMessage?> = .none,
        profileUpdateTimestamp: TimeInterval?,
        cacheSource: CacheSource = .libSession(fallback: .database),
        suppressUserProfileConfigUpdate: Bool = false,
        currentUserSessionIds: Set<String>,
        using dependencies: Dependencies
    ) throws {
        let isCurrentUser = currentUserSessionIds.contains(publicKey)
        let profile: Profile = cacheSource.resolve(db, publicKey: publicKey, using: dependencies)
        let updateStatus: UpdateStatus = UpdateStatus(
            updateTimestamp: profileUpdateTimestamp,
            cachedProfile: profile
        )
        var updatedProfile: Profile = profile
        var profileChanges: [ConfigColumnAssignment] = []
        
        /// We should only update profile info controled by other users if `updateStatus` is `shouldUpdate`
        if updateStatus == .shouldUpdate {
            /// Name
            switch (displayNameUpdate, isCurrentUser) {
                case (.none, _): break
                case (.currentUserUpdate(let name), true), (.contactUpdate(let name), false):
                    guard let name: String = name, !name.isEmpty, name != profile.name else { break }
                    
                    if profile.name != name {
                        updatedProfile = updatedProfile.with(name: name)
                        profileChanges.append(Profile.Columns.name.set(to: name))
                        db.addProfileEvent(id: publicKey, change: .name(name))
                    }
                    
                /// Don't want profiles in messages to modify the current users profile info so ignore those cases
                default: break
            }
            
            /// Blocks community message requests flag
            switch blocksCommunityMessageRequests {
                case .useExisting: break
                case .set(let value):
                    guard value != profile.blocksCommunityMessageRequests else { break }
                    
                    updatedProfile = updatedProfile.with(blocksCommunityMessageRequests: .set(to: value))
                    profileChanges.append(Profile.Columns.blocksCommunityMessageRequests.set(to: value))
            }
            
            /// Profile picture & profile key
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
                    /// If we have already downloaded the image then we can just directly update the stored profile data (it normally
                    /// wouldn't be updated until after the download completes)
                    let fileExists: Bool = ((try? dependencies[singleton: .displayPictureManager]
                        .path(for: url))
                        .map { dependencies[singleton: .fileManager].fileExists(atPath: $0) } ?? false)
                    
                    if fileExists {
                        if url != profile.displayPictureUrl {
                            /// Remove the old display picture (since we are replacing it)
                            if
                                let existingProfileUrl: String = updatedProfile.displayPictureUrl,
                                let existingFilePath: String = try? dependencies[singleton: .displayPictureManager]
                                    .path(for: existingProfileUrl)
                            {
                                Task.detached(priority: .low) {
                                    await dependencies[singleton: .imageDataManager].removeImage(
                                        identifier: existingFilePath
                                    )
                                    try? dependencies[singleton: .fileManager].removeItem(atPath: existingFilePath)
                                }
                            }
                            
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
            
            /// Session Pro Information (if it's not the current user)
            switch (proUpdate, isCurrentUser) {
                case (.none, _): break
                case (.contactUpdate(let value), false), (.currentUserUpdate(let value), true):
                    let proInfo: SessionPro.DecodedProForMessage = (value ?? .nonPro)
                    
                    switch proInfo.status {
                        case .valid:
                            let originalChangeCount: Int = profileChanges.count
                            let finalFeatures: SessionPro.Features = proInfo.features.profileOnlyFeatures
                            
                            if profile.proFeatures != finalFeatures {
                                updatedProfile = updatedProfile.with(proFeatures: .set(to: finalFeatures))
                                profileChanges.append(Profile.Columns.proFeatures.set(to: finalFeatures.rawValue))
                            }
                            
                            if profile.proExpiryUnixTimestampMs != proInfo.proProof.expiryUnixTimestampMs {
                                let value: UInt64 = proInfo.proProof.expiryUnixTimestampMs
                                updatedProfile = updatedProfile.with(proExpiryUnixTimestampMs: .set(to: value))
                                profileChanges.append(Profile.Columns.proExpiryUnixTimestampMs.set(to: value))
                            }
                            
                            if profile.proGenIndexHashHex != proInfo.proProof.genIndexHash.toHexString() {
                                let value: String = proInfo.proProof.genIndexHash.toHexString()
                                updatedProfile = updatedProfile.with(proGenIndexHashHex: .set(to: value))
                                profileChanges.append(Profile.Columns.proGenIndexHashHex.set(to: value))
                            }
                            
                            /// If the change count no longer matches then the pro status was updated so we need to emit an event
                            if profileChanges.count != originalChangeCount {
                                db.addProfileEvent(
                                    id: publicKey,
                                    change: .proStatus(
                                        isPro: true,
                                        features: finalFeatures,
                                        proExpiryUnixTimestampMs: proInfo.proProof.expiryUnixTimestampMs,
                                        proGenIndexHashHex: proInfo.proProof.genIndexHash.toHexString()
                                    )
                                )
                            }
                            
                        default:
                            let originalChangeCount: Int = profileChanges.count
                            
                            if profile.proFeatures != .none {
                                updatedProfile = updatedProfile.with(proFeatures: .set(to: .none))
                                profileChanges.append(Profile.Columns.proFeatures.set(to: .none))
                            }
                            
                            if profile.proExpiryUnixTimestampMs > 0 {
                                updatedProfile = updatedProfile.with(proExpiryUnixTimestampMs: .set(to: 0))
                                profileChanges.append(Profile.Columns.proExpiryUnixTimestampMs.set(to: 0))
                            }
                            
                            if profile.proGenIndexHashHex != nil {
                                updatedProfile = updatedProfile.with(proGenIndexHashHex: .set(to: nil))
                                profileChanges.append(Profile.Columns.proGenIndexHashHex.set(to: nil))
                            }
                            
                            /// If the change count no longer matches then the pro status was updated so we need to emit an event
                            if profileChanges.count != originalChangeCount {
                                db.addProfileEvent(
                                    id: publicKey,
                                    change: .proStatus(
                                        isPro: false,
                                        features: .none,
                                        proExpiryUnixTimestampMs: 0,
                                        proGenIndexHashHex: nil
                                    )
                                )
                            }
                    }
                    
                /// Don't want profiles in messages to modify the current users profile info so ignore those cases
                default: break
            }
        }
        
        /// Nickname - this is controlled by the current user so should always be used
        switch (nicknameUpdate, isCurrentUser) {
            case (.useExisting, _): break
            case (.set(let nickname), false):
                let finalNickname: String? = (nickname?.isEmpty == false ? nickname : nil)
                
                if profile.nickname != finalNickname {
                    updatedProfile = updatedProfile.with(nickname: .set(to: finalNickname))
                    profileChanges.append(Profile.Columns.nickname.set(to: finalNickname))
                    db.addProfileEvent(id: publicKey, change: .nickname(finalNickname))
                }
                
            default: break
        }
        
        /// Add a conversation event if the display name for a conversation changed
        let effectiveDisplayName: String? = {
            if isCurrentUser {
                guard case .currentUserUpdate(let name) = displayNameUpdate else { return nil }
                
                return name
            }
            
            if case .set(let nickname) = nicknameUpdate, let nickname, !nickname.isEmpty {
                return nickname
            }
            
            if case .contactUpdate(let name) = displayNameUpdate, let name, !name.isEmpty {
                return name
            }
            
            return nil
        }()

        if
            let newDisplayName: String = effectiveDisplayName,
            newDisplayName != (isCurrentUser ? profile.name : (profile.nickname ?? profile.name))
        {
            db.addConversationEvent(id: publicKey, type: .updated(.displayName(newDisplayName)))
        }
        
        /// If the profile was either updated or matches the current (latest) state then we should check if we have the display picture on
        /// disk and, if not, we should schedule a download (a display picture may not be present after linking devices, restoration, etc.)
        if updateStatus == .shouldUpdate || updateStatus == .matchesCurrent {
            var targetUrl: String? = profile.displayPictureUrl
            var targetKey: Data? = profile.displayPictureEncryptionKey
            
            switch displayPictureUpdate {
                case .contactUpdateTo(let url, let key), .currentUserUpdateTo(let url, let key, _):
                    targetUrl = url
                    targetKey = key
                    
                default: break
            }
            
            if
                let url: String = targetUrl,
                let key: Data = targetKey,
                !key.isEmpty,
                let path: String = try? dependencies[singleton: .displayPictureManager].path(for: url),
                !dependencies[singleton: .fileManager].fileExists(atPath: path)
            {
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
        }
        
        /// Persist any changes
        if !profileChanges.isEmpty {
            let changeString: String = db.currentEvents()
                .filter { $0.key.generic == .profile }
                .compactMap {
                    switch ($0.value as? ProfileEvent)?.change {
                        case .none: return nil
                        case .name: return "name updated"   // stringlint:ignore
                        case .displayPictureUrl(let url):
                            return (url != nil ? "displayPictureUrl updated" : "displayPictureUrl removed") // stringlint:ignore
                            
                        case .nickname(let nickname):
                            return (nickname != nil ? "nickname updated" :  "nickname removed") // stringlint:ignore
                            
                        case .proStatus(let isPro, let features, _, _):
                            return "pro state - \(isPro ? "enabled: \(features)" :  "disabled")" // stringlint:ignore
                    }
                }
                .joined(separator: ", ")
            updatedProfile = updatedProfile.with(profileLastUpdated: .set(to: profileUpdateTimestamp))
            profileChanges.append(Profile.Columns.profileLastUpdated.set(to: profileUpdateTimestamp))
            
            try updatedProfile.upsert(db)
            
            try Profile
                .filter(id: publicKey)
                .updateAllAndConfig(
                    db,
                    profileChanges,
                    using: dependencies
                )
            
            /// We don't automatically update the current users profile data when changed in the database so need to manually
            /// trigger the update
            if !suppressUserProfileConfigUpdate, isCurrentUser {
                let userSessionId: SessionId = dependencies[cache: .general].sessionId
                
                try dependencies.mutate(cache: .libSession) { cache in
                    try cache.performAndPushChange(db, for: .userProfile, sessionId: userSessionId) { _ in
                        try cache.updateProfile(
                            displayName: .set(to: updatedProfile.name),
                            displayPictureUrl: .set(to: updatedProfile.displayPictureUrl),
                            displayPictureEncryptionKey: .set(to: updatedProfile.displayPictureEncryptionKey),
                            proFeatures: .set(to: updatedProfile.proFeatures),
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
            
            Log.custom(isCurrentUser ? .info : .debug, [.profile], "Successfully updated \(isCurrentUser ? "user profile" : "profile for \(publicKey)")) (\(changeString)).")
        }
    }
}
