// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import GRDB
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
    
    public static func run<S: Scheduler>(
        _ job: Job,
        scheduler: S,
        success: @escaping (Job, Bool) -> Void,
        failure: @escaping (Job, Error, Bool) -> Void,
        deferred: @escaping (Job) -> Void,
        using dependencies: Dependencies
    ) {
        guard
            let detailsData: Data = job.details,
            let details: Details = try? JSONDecoder(using: dependencies).decode(Details.self, from: detailsData)
        else { return failure(job, JobRunnerError.missingRequiredDetails, true) }
        
        Task {
            do {
                let request: Network.PreparedRequest<Data> = try await dependencies[singleton: .storage].readAsync { db in
                    switch details.target {
                        case .profile(_, let url, _), .group(_, let url, _):
                            guard let downloadUrl: URL = URL(string: url) else {
                                throw NetworkError.invalidURL
                            }
                            
                            return try Network.preparedDownload(
                                url: downloadUrl,
                                using: dependencies
                            )
                            
                        case .community(let fileId, let roomToken, let server, let skipAuthentication):
                            guard
                                let info: LibSession.OpenGroupCapabilityInfo = try? LibSession.OpenGroupCapabilityInfo
                                    .fetchOne(db, id: OpenGroup.idFor(roomToken: roomToken, server: server))
                            else { throw JobRunnerError.missingRequiredDetails }
                            
                            return try Network.SOGS.preparedDownload(
                                fileId: fileId,
                                roomToken: roomToken,
                                authMethod: Authentication.community(info: info),
                                skipAuthentication: skipAuthentication,
                                using: dependencies
                            )
                    }
                }
                try Task.checkCancellation()
                
                let downloadUrl: String = ((try? request.generateUrl())?.absoluteString ?? request.path)
                let filePath: String = try dependencies[singleton: .displayPictureManager]
                    .path(for: downloadUrl)
                
                guard !dependencies[singleton: .fileManager].fileExists(atPath: filePath) else {
                    throw AttachmentError.alreadyDownloaded(downloadUrl)
                }
                
                // FIXME: Make this async/await when the refactored networking is merged
                let response: Data = try await request
                    .send(using: dependencies)
                    .values
                    .first(where: { _ in true })?.1 ?? { throw AttachmentError.downloadFailed }()
                try Task.checkCancellation()
                
                /// Check to make sure this download is still a valid update
                try await dependencies[singleton: .storage].readAsync { db in
                    try details.ensureValidUpdate(db, using: dependencies)
                }
                
                /// Get the decrypted data
                guard
                    let decryptedData: Data = {
                        switch (details.target, Network.FileServer.usesDeterministicEncryption(downloadUrl)) {
                            case (.community, _): return response    /// Community data is unencrypted
                            case (.profile(_, _, let encryptionKey), false), (.group(_, _, let encryptionKey), false):
                                return dependencies[singleton: .crypto].generate(
                                    .legacyDecryptedDisplayPicture(data: response, key: encryptionKey)
                                )
                                
                            case (.profile(_, _, let encryptionKey), true), (.group(_, _, let encryptionKey), true):
                                return dependencies[singleton: .crypto].generate(
                                    .decryptAttachment(ciphertext: response, key: encryptionKey)
                                )
                        }
                    }()
                else { throw AttachmentError.writeFailed }
                
                /// Ensure it's a valid image
                guard
                    UIImage(data: decryptedData) != nil,
                    dependencies[singleton: .fileManager].createFile(
                        atPath: filePath,
                        contents: decryptedData
                    )
                else { throw AttachmentError.invalidData }
                
                /// Kick off a task to load the image into the cache (assuming we want to render it soon)
                Task.detached(priority: .userInitiated) {
                    await dependencies[singleton: .imageDataManager].load(
                        .url(URL(fileURLWithPath: filePath))
                    )
                }
                
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
                
                return scheduler.schedule {
                    success(job, false)
                }
            }
            catch AttachmentError.downloadNoLongerValid {
                return scheduler.schedule {
                    success(job, false)
                }
            }
            catch AttachmentError.alreadyDownloaded(let downloadUrl) {
                /// If the file already exists then write the changes to the database
                do {
                    try await dependencies[singleton: .storage].writeAsync { db in
                        try writeChanges(
                            db,
                            details: details,
                            downloadUrl: downloadUrl,
                            using: dependencies
                        )
                    }
                    
                    return scheduler.schedule {
                        success(job, false)
                    }
                }
                catch {
                    return scheduler.schedule {
                        failure(job, error, true)
                    }
                }
            }
            catch JobRunnerError.missingRequiredDetails {
                return scheduler.schedule {
                    failure(job, JobRunnerError.missingRequiredDetails, true)
                }
            }
            catch AttachmentError.invalidPath {
                return scheduler.schedule {
                    Log.error(.cat, "Failed to generate display picture file path for \(details.target)")
                    failure(job, AttachmentError.invalidPath, true)
                }
            }
            catch AttachmentError.writeFailed {
                return scheduler.schedule {
                    Log.error(.cat, "Failed to decrypt display picture for \(details.target)")
                    failure(job, AttachmentError.writeFailed, true)
                }
            }
            catch AttachmentError.invalidData {
                return scheduler.schedule {
                    Log.error(.cat, "Failed to load display picture for \(details.target)")
                    failure(job, AttachmentError.invalidData, true)
                }
            }
            catch {
                return scheduler.schedule {
                    failure(job, error, true)
                }
            }
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
                db.addConversationEvent(id: id, type: .updated(.displayPictureUrl(url)))
                
            case .group(let id, let url, let encryptionKey):
                _ = try? ClosedGroup
                    .filter(id: id)
                    .updateAllAndConfig(
                        db,
                        ClosedGroup.Columns.displayPictureUrl.set(to: url),
                        ClosedGroup.Columns.displayPictureEncryptionKey.set(to: encryptionKey),
                        using: dependencies
                    )
                db.addConversationEvent(id: id, type: .updated(.displayPictureUrl(url)))
                
            case .community(_, let roomToken, let server, _):
                _ = try? OpenGroup
                    .filter(id: OpenGroup.idFor(roomToken: roomToken, server: server))
                    .updateAllAndConfig(
                        db,
                        OpenGroup.Columns.displayPictureOriginalUrl.set(to: downloadUrl),
                        using: dependencies
                    )
                db.addConversationEvent(
                    id: OpenGroup.idFor(roomToken: roomToken, server: server),
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
        case community(imageId: String, roomToken: String, server: String, skipAuthentication: Bool = false)
        
        var isValid: Bool {
            switch self {
                case .profile(_, let url, let encryptionKey), .group(_, let url, let encryptionKey):
                    return (
                        !url.isEmpty &&
                        Network.FileServer.fileId(for: url) != nil &&
                        encryptionKey.count == DisplayPictureManager.encryptionKeySize
                    )
                    
                case .community(let imageId, _, _, _): return !imageId.isEmpty
            }
        }
        
        // MARK: - CustomStringConvertible
        
        public var description: String {
            switch self {
                case .profile(let id, _, _): return "profile: \(id)"
                case .group(let id, _, _): return "group: \(id)"
                case .community(_, let roomToken, let server, _): return "room: \(roomToken) on server: \(server)"
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
                    case .community(let imageId, let roomToken, let server, let skipAuthentication):
                        return .community(
                            imageId: imageId,
                            roomToken: roomToken,
                            server: server.lowercased(),   // Always in lowercase on `OpenGroup`
                            skipAuthentication: skipAuthentication
                        )
                        
                    default: return target
                }
            }()
            self.timestamp = timestamp
        }
        
        public init?(owner: DisplayPictureManager.Owner) {
            switch owner {
                case .user(let profile):
                    guard
                        let url: String = profile.displayPictureUrl,
                        let key: Data = profile.displayPictureEncryptionKey,
                        let details: Details = Details(
                            target: .profile(id: profile.id, url: url, encryptionKey: key),
                            timestamp: profile.profileLastUpdated
                        )
                    else { return nil }
                    
                    self = details
                    
                case .group(let group):
                    guard
                        let url: String = group.displayPictureUrl,
                        let key: Data = group.displayPictureEncryptionKey,
                        let details: Details = Details(
                            target: .group(id: group.id, url: url, encryptionKey: key),
                            timestamp: nil
                        )
                    else { return nil }
                    
                    self = details
                    
                case .community(let openGroup):
                    guard
                        let imageId: String = openGroup.imageId,
                        let details: Details = Details(
                            target: .community(
                                imageId: imageId,
                                roomToken: openGroup.roomToken,
                                server: openGroup.server
                            ),
                            timestamp: nil
                        )
                    else { return nil }
                    
                    self = details
                    
                case .file: return nil
            }
        }
        
        // MARK: - Functions
        
        fileprivate func ensureValidUpdate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
            switch self.target {
                case .profile(let id, let url, let encryptionKey):
                    guard let latestProfile: Profile = try? Profile.fetchOne(db, id: id) else {
                        throw AttachmentError.downloadNoLongerValid
                    }
                    
                    /// If the data matches what is stored in the database then we should be fine to consider it valid (it may be that
                    /// we are re-downloading a profile due to some invalid state)
                    let dataMatches: Bool = (
                        encryptionKey == latestProfile.displayPictureEncryptionKey &&
                        url == latestProfile.displayPictureUrl
                    )
                    
                    guard
                        Profile.shouldUpdateProfile(timestamp, profile: latestProfile, using: dependencies) ||
                            dataMatches
                    else { throw AttachmentError.downloadNoLongerValid }
                    
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
                    
                case .community(let imageId, let roomToken, let server, _):
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
