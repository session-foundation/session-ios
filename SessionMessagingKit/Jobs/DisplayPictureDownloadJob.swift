// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import GRDB
import SessionUIKit
import SessionUtilitiesKit
import SessionNetworkingKit

// MARK: - Log.Category

private extension Log.Category {
    static let cat: Log.Category = .create("DisplayPictureDownloadJob", defaultLevel: .info)
}

// MARK: - DisplayPictureDownloadJob

public enum DisplayPictureDownloadJob: JobExecutor {
    public static var maxFailureCount: Int = 1
    public static var requiresThreadId: Bool = false
    public static var requiresInteractionId: Bool = false
    public static var canBePreempted: Bool = true
    public static let requiresForeground: Bool = true
    
    public static func canRunConcurrentlyWith(
        runningJobs: [JobState],
        jobState: JobState,
        using dependencies: Dependencies
    ) -> Bool {
        guard
            let detailsData: Data = jobState.job.details,
            let details: Details = try? JSONDecoder(using: dependencies)
                .decode(Details.self, from: detailsData)
        else { return true }    /// If we can't get the details then just run the job (it'll fail permanently)
        
        /// Multiple `DisplayPictureDownloadJobs` can be triggered for the same image since they are scheduled when
        /// receiving messages so if we already have one that is running for the same data then should let it complete first
        return !runningJobs.contains { otherJobState in
            guard
                let otherDetailsData: Data = otherJobState.job.details,
                let otherDetails: Details = try? JSONDecoder(using: dependencies)
                    .decode(Details.self, from: otherDetailsData)
            else { return false }
            
            return (details.target == otherDetails.target)
        }
    }
    
    public static func run(_ job: Job, using dependencies: Dependencies) async throws -> JobExecutionResult {
        guard
            let detailsData: Data = job.details,
            let details: Details = try? JSONDecoder(using: dependencies).decode(Details.self, from: detailsData)
        else { throw JobRunnerError.missingRequiredDetails }
        
        do {
            /// Check to make sure this download is a valid update before starting to download
            try await dependencies[singleton: .storage].readAsync { db in
                try details.ensureValidUpdate(db, using: dependencies)
            }
            try Task.checkCancellation()
            
            let downloadUrl: String = details.target.downloadUrl
            let filePath: String = try dependencies[singleton: .displayPictureManager]
                .path(for: downloadUrl)
            
            /// If the file already exists then write the changes to the database
            guard !dependencies[singleton: .fileManager].fileExists(atPath: filePath) else {
                try await dependencies[singleton: .storage].writeAsync { db in
                    try writeChanges(
                        db,
                        details: details,
                        downloadUrl: downloadUrl,
                        using: dependencies
                    )
                }
                
                return .success
            }
            
            let response: (temporaryFilePath: String, metadata: FileMetadata)
            
            switch details.target {
                case .profile(_, let url, _), .group(_, let url, _):
                    response = try await dependencies[singleton: .network].download(
                        downloadUrl: url,
                        stallTimeout: Network.fileDownloadTimeout,
                        requestTimeout: Network.fileDownloadTimeout,
                        overallTimeout: Network.fileDownloadTimeout,
                        partialMinInterval: Network.fileDownloadMinInterval,
                        desiredPathIndex: nil,
                        onProgress: nil
                    )
                    
                case .community(let fileId, let roomToken, let server, let publicKey, let skipAuthentication):
                    let request: Network.PreparedRequest<Data> = try Network.SOGS.preparedDownload(
                        fileId: fileId,
                        roomToken: roomToken,
                        authMethod: try await {
                            /// If we don't need to authenticate then don't bother trying to retrieve the capability info (just
                            /// return pre-made auth info
                            if skipAuthentication {
                                return Authentication.Community(
                                    roomToken: roomToken,
                                    server: server,
                                    publicKey: publicKey,
                                    hasCapabilities: false,
                                    supportsBlinding: false,
                                    forceBlinded: false
                                )
                            }
                            
                            /// Otherwise get the auth details from the `CommunityManager` (or throw if we don't have any
                            /// since auth is meant to be required)
                            return try await dependencies[singleton: .communityManager]
                                .server(server)?
                                .authMethod() ?? { throw CryptoError.invalidAuthentication }()
                        }(),
                        skipAuthentication: skipAuthentication,
                        using: dependencies
                    )
                    let responseData: Data = try await request.send(using: dependencies)
                    
                    /// Store the encrypted data temporarily
                    let temporaryFilePath: String = dependencies[singleton: .fileManager].temporaryFilePath()
                    try dependencies[singleton: .fileManager].write(
                        data: responseData,
                        toPath: temporaryFilePath
                    )
                    response = (
                        temporaryFilePath,
                        FileMetadata(id: fileId, size: UInt64(responseData.count))
                    )
            }
            try Task.checkCancellation()
            
            /// Check to make sure this download is still a valid update after completing the download
            try await dependencies[singleton: .storage].readAsync { db in
                try details.ensureValidUpdate(db, using: dependencies)
            }
            
            /// Decrypt the data if needed
            let usesStreamBasedAttachmentEncryption: Bool = dependencies[singleton: .crypto].verify(
                .usesStreamBasedAttachmentEncryption(downloadUrl: downloadUrl)
            )
            
            do {
                switch (details.target, usesStreamBasedAttachmentEncryption) {
                    case (.profile(_, _, let encryptionKey), false), (.group(_, _, let encryptionKey), false):
                        let ciphertext: Data = try dependencies[singleton: .fileManager].contents(atPath: response.temporaryFilePath)
                        let plaintext: Data = try dependencies[singleton: .crypto].tryGenerate(
                            .legacyDecryptedDisplayPicture(data: ciphertext, key: encryptionKey)
                        )
                        try Task.checkCancellation()
                        
                        try dependencies[singleton: .fileManager].write(
                            data: plaintext,
                            toPath: filePath
                        )
                        
                    case (.profile(_, _, let encryptionKey), true) where !encryptionKey.isEmpty,
                        (.group(_, _, let encryptionKey), true) where !encryptionKey.isEmpty:
                        try dependencies[singleton: .crypto].tryGenerate(
                            .decryptAttachmentToFile(
                                filePath: response.temporaryFilePath,
                                destinationPath: filePath,
                                key: encryptionKey
                            )
                        )
                        
                    case (.community, _), (.profile, _), (.group, _):
                        /// File is in plaintext so just move it to the destination
                        try dependencies[singleton: .fileManager].moveItem(
                            atPath: response.temporaryFilePath,
                            toPath: filePath
                        )
                }
            }
            catch {
                Log.error(.cat, "Failed to decrypt display picture for \(details.target)")
                throw AttachmentError.writeFailed
            }
            try Task.checkCancellation()
            
            /// Ensure it's a valid image (if not then remove it from the final location)
            guard dependencies[singleton: .imageDataManager].isValidImage(at: filePath) else {
                try? dependencies[singleton: .fileManager].removeItem(atPath: filePath)
                Log.error(.cat, "Failed to load display picture for \(details.target)")
                throw AttachmentError.invalidData
            }
            
            /// Kick off a task to load the image into the cache (assuming we want to render it soon)
            Task.detached(priority: .userInitiated) { [dependencies] in
                await dependencies[singleton: .imageDataManager].load(
                    .url(URL(fileURLWithPath: filePath))
                )
            }
            
            /// Remove the old display picture (since we are replacing it)
            let existingProfileUrl: String? = try? await dependencies[singleton: .storage].readAsync { db in
                switch details.target {
                    case .profile(let id, _, _):
                        /// We should consider `libSession` the source-of-truth for profile data for contacts so try to retrieve the profile data from
                        /// there before falling back to the one fetched from the database
                        return try? (
                            dependencies.mutate(cache: .libSession) {
                                $0.profile(contactId: id)?.displayPictureUrl
                            } ??
                            Profile
                                .filter(id: id)
                                .select(.displayPictureUrl)
                                .asRequest(of: String.self)
                                .fetchOne(db)
                        )
                        
                    case .group(let id, _, _):
                        return try? ClosedGroup
                            .filter(id: id)
                            .select(.displayPictureUrl)
                            .asRequest(of: String.self)
                            .fetchOne(db)
                        
                    case .community(_, let roomToken, let server, _, _):
                        return try? OpenGroup
                            .filter(id: OpenGroup.idFor(roomToken: roomToken, server: server))
                            .select(.displayPictureOriginalUrl)
                            .asRequest(of: String.self)
                            .fetchOne(db)
                }
            }
            try Task.checkCancellation()
            
            /// Store the updated information in the database (this will generally result in the UI refreshing as it'll observe
            /// the `downloadUrl` changing)
            try await dependencies[singleton: .storage].writeAsync { db in
                try writeChanges(
                    db,
                    details: details,
                    downloadUrl: downloadUrl,
                    using: dependencies
                )
            }
            try Task.checkCancellation()
            
            /// Remove the old display picture (as long as it's different from the new one)
            if
                let existingProfileUrl: String = existingProfileUrl,
                existingProfileUrl != downloadUrl,
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
            
            return .success
        }
        catch AttachmentError.downloadNoLongerValid {
            return .success
        }
        catch AttachmentError.invalidPath {
            Log.error(.cat, "Failed to generate display picture file path for \(details.target)")
            throw JobRunnerError.permanentFailure(AttachmentError.invalidPath)
        }
        catch {
            throw JobRunnerError.permanentFailure(error)
        }
    }

    private static func writeChanges(
        _ db: ObservingDatabase,
        details: Details,
        downloadUrl: String?,
        using dependencies: Dependencies
    ) throws {
        switch details.target {
            case .profile(let id, let url, let encryptionKey):
                _ = try? Profile
                    .filter(id: id)
                    .updateAllAndConfig(
                        db,
                        Profile.Columns.displayPictureUrl.set(to: url),
                        Profile.Columns.displayPictureEncryptionKey.set(to: encryptionKey),
                        Profile.Columns.profileLastUpdated.set(to: details.timestamp),
                        using: dependencies
                    )
                
                db.addProfileEvent(id: id, change: .displayPictureUrl(url))
                db.addConversationEvent(
                    id: id,
                    variant: .contact,
                    type: .updated(.displayPictureUrl(url))
                )
                
            case .group(let id, let url, let encryptionKey):
                _ = try? ClosedGroup
                    .filter(id: id)
                    .updateAllAndConfig(
                        db,
                        ClosedGroup.Columns.displayPictureUrl.set(to: url),
                        ClosedGroup.Columns.displayPictureEncryptionKey.set(to: encryptionKey),
                        using: dependencies
                    )
                db.addConversationEvent(
                    id: id,
                    variant: .group,
                    type: .updated(.displayPictureUrl(url))
                )
                
            case .community(_, let roomToken, let server, _, _):
                _ = try? OpenGroup
                    .filter(id: OpenGroup.idFor(roomToken: roomToken, server: server))
                    .updateAllAndConfig(
                        db,
                        OpenGroup.Columns.displayPictureOriginalUrl.set(to: downloadUrl),
                        using: dependencies
                    )
                db.addConversationEvent(
                    id: OpenGroup.idFor(roomToken: roomToken, server: server),
                    variant: .community,
                    type: .updated(.displayPictureUrl(downloadUrl))
                )
        }
    }
}

// MARK: - DisplayPictureDownloadJob.Details

extension DisplayPictureDownloadJob {
    public enum Target: Codable, Hashable, CustomStringConvertible {
        case profile(id: String, url: String, encryptionKey: Data)
        case group(id: String, url: String, encryptionKey: Data)
        case community(imageId: String, roomToken: String, server: String, publicKey: String, skipAuthentication: Bool = false)
        
        var isValid: Bool {
            switch self {
                case .community(let imageId, _, _, _, _): return !imageId.isEmpty
                case .profile(_, let url, let encryptionKey), .group(_, let url, let encryptionKey):
                    return (
                        !url.isEmpty &&
                        Network.FileServer.fileId(for: url) != nil &&
                        encryptionKey.count == DisplayPictureManager.encryptionKeySize
                    )
            }
        }
        
        var downloadUrl: String {
            switch self {
                case .profile(_, let url, _), .group(_, let url, _): return url
                case .community(let fileId, let roomToken, let server, _, _):
                    return Network.SOGS.downloadUrlString(for: fileId, server: server, roomToken: roomToken)
            }
        }
        
        // MARK: - CustomStringConvertible
        
        public var description: String {
            switch self {
                case .profile(let id, _, _): return "profile: \(id)"
                case .group(let id, _, _): return "group: \(id)"
                case .community(_, let roomToken, let server, _, _): return "room: \(roomToken) on server: \(server)"
            }
        }
    }
    
    public struct Details: Codable, Hashable {
        public let target: Target
        public let timestamp: TimeInterval?
        
        // MARK: - Hashable
        
        public func hash(into hasher: inout Hasher) {
            /// We intentionally leave `timestamp` out of the hash value because when we insert the job we want
            /// it to prevent duplicate jobs from being added with the same `target` information and including
            /// the `timestamp` could likely result in multiple jobs downloading the same `target`
            target.hash(into: &hasher)
        }
        
        // MARK: - Initialization
        
        public init?(target: Target, timestamp: TimeInterval?) {
            guard target.isValid else { return nil }
            
            self.target = {
                switch target {
                    case .community(let imageId, let roomToken, let server, let publicKey, let skipAuthentication):
                        return .community(
                            imageId: imageId,
                            roomToken: roomToken,
                            server: server.lowercased(),   // Always in lowercase on `OpenGroup`
                            publicKey: publicKey,
                            skipAuthentication: skipAuthentication
                        )
                        
                    default: return target
                }
            }()
            self.timestamp = timestamp
        }
        
        // MARK: - Functions
        
        fileprivate func ensureValidUpdate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
            switch self.target {
                case .profile(let id, let url, let encryptionKey):
                    /// We should consider `libSession` the source-of-truth for profile data for contacts so try to retrieve the profile data from
                    /// there before falling back to the one fetched from the database
                    let maybeLatestProfile: Profile? = try? (
                        dependencies.mutate(cache: .libSession) { $0.profile(contactId: id) } ??
                        Profile.fetchOne(db, id: id)
                    )
                    
                    guard let latestProfile: Profile = maybeLatestProfile else {
                        throw AttachmentError.downloadNoLongerValid
                    }
                    
                    /// If the data matches what is stored in the database then we should be fine to consider it valid (it may be that
                    /// we are re-downloading a profile due to some invalid state)
                    let dataMatches: Bool = (
                        encryptionKey == latestProfile.displayPictureEncryptionKey &&
                        url == latestProfile.displayPictureUrl
                    )
                    let updateStatus: Profile.UpdateStatus = Profile.UpdateStatus(
                        updateTimestamp: timestamp,
                        cachedProfile: latestProfile
                    )
                    
                    guard dataMatches || updateStatus == .shouldUpdate || updateStatus == .matchesCurrent else {
                        throw AttachmentError.downloadNoLongerValid
                    }
                    
                    break
                    
                case .group(let id, let url,_):
                    /// Groups now rely on a `GroupInfo` config message which has a proper `seqNo` so we don't need any
                    /// `displayPictureLastUpdated` hacks to ensure we have the last one (the `displayPictureUrl`
                    /// will always be correct)
                    guard
                        let latestDisplayPictureUrl: String = dependencies.mutate(cache: .libSession, { cache in
                            cache.displayPictureUrl(threadId: id, threadVariant: .group)
                        }),
                        url == latestDisplayPictureUrl
                    else { throw AttachmentError.downloadNoLongerValid }
                    
                    break
                    
                case .community(let imageId, let roomToken, let server, _, _):
                    guard
                        let latestImageId: String = try? OpenGroup
                            .select(.imageId)
                            .filter(id: OpenGroup.idFor(roomToken: roomToken, server: server))
                            .asRequest(of: String.self)
                            .fetchOne(db),
                        imageId == latestImageId
                    else { throw AttachmentError.downloadNoLongerValid }
                    
                    break
            }
        }
    }
}
