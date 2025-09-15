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
        
        dependencies[singleton: .storage]
            .readPublisher { db -> Network.PreparedRequest<Data> in
                switch details.target {
                    case .profile(_, let url, _), .group(_, let url, _):
                        guard
                            let fileId: String = Network.FileServer.fileId(for: url),
                            let downloadUrl: URL = URL(string: Network.FileServer.downloadUrlString(for: url, fileId: fileId))
                        else { throw NetworkError.invalidURL }
                        
                        return try Network.preparedDownload(
                            url: downloadUrl,
                            using: dependencies
                        )
                        
                    case .community(let fileId, let roomToken, let server):
                        guard
                            let info: LibSession.OpenGroupCapabilityInfo = try? LibSession.OpenGroupCapabilityInfo
                                .fetchOne(db, id: OpenGroup.idFor(roomToken: roomToken, server: server))
                        else { throw JobRunnerError.missingRequiredDetails }
                        
                        return try Network.SOGS.preparedDownload(
                            fileId: fileId,
                            roomToken: roomToken,
                            authMethod: Authentication.community(info: info),
                            using: dependencies
                        )
                }
            }
            .tryMap { (preparedDownload: Network.PreparedRequest<Data>) -> Network.PreparedRequest<(Data, String, URL?, Date?)> in
                guard
                    let filePath: String = try? dependencies[singleton: .displayPictureManager].path(
                        for: (preparedDownload.destination.url?.absoluteString)
                            .defaulting(to: preparedDownload.destination.urlPathAndParamsString)
                    )
                else { throw DisplayPictureError.invalidPath }
                
                guard !dependencies[singleton: .fileManager].fileExists(atPath: filePath) else {
                    throw DisplayPictureError.alreadyDownloaded(preparedDownload.destination.url)
                }
                
                return preparedDownload.map { info, data in
                    (data, filePath, preparedDownload.destination.url, Date.fromHTTPExpiresHeaders(info.headers["Expires"]))
                }
            }
            .flatMap { $0.send(using: dependencies) }
            .map { _, result in result }
            .subscribe(on: scheduler, using: dependencies)
            .receive(on: scheduler, using: dependencies)
            .flatMapStorageReadPublisher(using: dependencies) { (db: ObservingDatabase, result: (Data, String, URL?, Date?)) -> (Data, String, URL?, Date?) in
                /// Check to make sure this download is still a valid update
                guard details.isValidUpdate(db, using: dependencies) else {
                    throw DisplayPictureError.updateNoLongerValid
                }
                
                return result
            }
            .tryMap { (data: Data, filePath: String, downloadUrl: URL?, expires: Date?) -> (URL?, Date?) in
                guard
                    let decryptedData: Data = {
                        switch details.target {
                            case .community: return data    // Community data is unencrypted
                            case .profile(_, _, let encryptionKey), .group(_, _, let encryptionKey):
                                return dependencies[singleton: .crypto].generate(
                                    .decryptedDataDisplayPicture(data: data, key: encryptionKey)
                                )
                        }
                    }()
                else { throw DisplayPictureError.writeFailed }
                
                guard
                    UIImage(data: decryptedData) != nil,
                    dependencies[singleton: .fileManager].createFile(
                        atPath: filePath,
                        contents: decryptedData
                    )
                else { throw DisplayPictureError.loadFailed }
                
                /// Kick off a task to load the image into the cache (assuming we want to render it soon)
                Task(priority: .userInitiated) {
                    await dependencies[singleton: .imageDataManager].load(
                        .url(URL(fileURLWithPath: filePath))
                    )
                }
                
                return (downloadUrl, expires)
            }
            .flatMapStorageWritePublisher(using: dependencies) { (db: ObservingDatabase, result: (downloadUrl: URL?, expires: Date?)) in
                /// Store the updated information in the database (this will generally result in the UI refreshing as it'll observe
                /// the `downloadUrl` changing)
                try writeChanges(
                    db,
                    details: details,
                    downloadUrl: result.downloadUrl,
                    expires: result.expires,
                    using: dependencies
                )
            }
            .sinkUntilComplete(
                receiveCompletion: { result in
                    switch (result, result.errorOrNull, result.errorOrNull as? DisplayPictureError) {
                        case (.finished, _, _): success(job, false)
                        case (_, _, .updateNoLongerValid): success(job, false)
                        case (_, _, .alreadyDownloaded(let downloadUrl)):
                            /// If the file already exists then write the changes to the database
                            dependencies[singleton: .storage].writeAsync(
                                updates: { db in
                                    try writeChanges(
                                        db,
                                        details: details,
                                        downloadUrl: downloadUrl,
                                        expires: nil,
                                        using: dependencies
                                    )
                                },
                                completion: { result in
                                    switch result {
                                        case .success: success(job, false)
                                        case .failure(let error): failure(job, error, true)
                                    }
                                }
                            )
                            
                        case (_, let error as JobRunnerError, _) where error == .missingRequiredDetails:
                            failure(job, error, true)
                            
                        case (_, _, .invalidPath):
                            Log.error(.cat, "Failed to generate display picture file path for \(details.target)")
                            failure(job, DisplayPictureError.invalidPath, true)
                            
                        case (_, _, .writeFailed):
                            Log.error(.cat, "Failed to decrypt display picture for \(details.target)")
                            failure(job, DisplayPictureError.writeFailed, true)
                            
                        case (_, _, .loadFailed):
                            Log.error(.cat, "Failed to load display picture for \(details.target)")
                            failure(job, DisplayPictureError.loadFailed, true)
                            
                        case (.failure(let error), _, _): failure(job, error, true)
                    }
                }
            )
    }

    private static func writeChanges(
        _ db: ObservingDatabase,
        details: Details,
        downloadUrl: URL?,
        expires: Date?,
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
            
                if dependencies[cache: .general].sessionId.hexString == id, let expires: Date = expires {
                    dependencies[defaults: .standard, key: .profilePictureExpiresDate] = expires
                }
                
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
                
            case .community(_, let roomToken, let server):
                _ = try? OpenGroup
                    .filter(id: OpenGroup.idFor(roomToken: roomToken, server: server))
                    .updateAllAndConfig(
                        db,
                        OpenGroup.Columns.displayPictureOriginalUrl.set(to: downloadUrl),
                        using: dependencies
                    )
                db.addConversationEvent(
                    id: OpenGroup.idFor(roomToken: roomToken, server: server),
                    type: .updated(.displayPictureUrl(downloadUrl?.absoluteString))
                )
        }
    }
}

// MARK: - DisplayPictureDownloadJob.Details

extension DisplayPictureDownloadJob {
    public enum Target: Codable, Hashable, CustomStringConvertible {
        case profile(id: String, url: String, encryptionKey: Data)
        case group(id: String, url: String, encryptionKey: Data)
        case community(imageId: String, roomToken: String, server: String)
        
        var isValid: Bool {
            switch self {
                case .profile(_, let url, let encryptionKey), .group(_, let url, let encryptionKey):
                    return (
                        !url.isEmpty &&
                        Network.FileServer.fileId(for: url) != nil &&
                        encryptionKey.count == DisplayPictureManager.aes256KeyByteLength
                    )
                    
                case .community(let imageId, _, _): return !imageId.isEmpty
            }
        }
        
        // MARK: - CustomStringConvertible
        
        public var description: String {
            switch self {
                case .profile(let id, _, _): return "profile: \(id)"
                case .group(let id, _, _): return "group: \(id)"
                case .community(_, let roomToken, let server): return "room: \(roomToken) on server: \(server)"
            }
        }
    }
    
    public struct Details: Codable, Hashable {
        public let target: Target
        public let timestamp: TimeInterval
        
        // MARK: - Hashable
        
        public func hash(into hasher: inout Hasher) {
            /// We intentionally leave `timestamp` out of the hash value because when we insert the job we want
            /// it to prevent duplicate jobs from being added with the same `target` information and including
            /// the `timestamp` could likely result in multiple jobs downloading the same `target`
            target.hash(into: &hasher)
        }
        
        // MARK: - Initialization
        
        public init?(target: Target, timestamp: TimeInterval) {
            guard target.isValid else { return nil }
            
            self.target = {
                switch target {
                    case .community(let imageId, let roomToken, let server):
                        return .community(
                            imageId: imageId,
                            roomToken: roomToken,
                            server: server.lowercased()   // Always in lowercase on `OpenGroup`
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
                            timestamp: (profile.profileLastUpdated ?? 0)
                        )
                    else { return nil }
                    
                    self = details
                    
                case .group(let group):
                    guard
                        let url: String = group.displayPictureUrl,
                        let key: Data = group.displayPictureEncryptionKey,
                        let details: Details = Details(
                            target: .group(id: group.id, url: url, encryptionKey: key),
                            timestamp: 0
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
                            timestamp: 0
                        )
                    else { return nil }
                    
                    self = details
                    
                case .file: return nil
            }
        }
        
        // MARK: - Functions
        
        fileprivate func isValidUpdate(_ db: ObservingDatabase, using dependencies: Dependencies) -> Bool {
            switch self.target {
                case .profile(let id, let url, let encryptionKey):
                    guard let latestProfile: Profile = try? Profile.fetchOne(db, id: id) else { return false }
                    
                    return (
                        timestamp >= (latestProfile.profileLastUpdated ?? 0) || (
                            encryptionKey == latestProfile.displayPictureEncryptionKey &&
                            url == latestProfile.displayPictureUrl
                        )
                    )
                    
                case .group(let id, let url,_):
                    /// Groups now rely on a `GroupInfo` config message which has a proper `seqNo` so we don't need any
                    /// `displayPictureLastUpdated` hacks to ensure we have the last one (the `displayPictureUrl`
                    /// will always be correct)
                    guard
                        let latestDisplayPictureUrl: String = dependencies.mutate(cache: .libSession, { cache in
                            cache.displayPictureUrl(threadId: id, threadVariant: .group)
                        })
                    else { return false }
                    
                    return (url == latestDisplayPictureUrl)
                    
                case .community(let imageId, let roomToken, let server):
                    guard
                        let latestImageId: String = try? OpenGroup
                            .select(.imageId)
                            .filter(id: OpenGroup.idFor(roomToken: roomToken, server: server))
                            .asRequest(of: String.self)
                            .fetchOne(db)
                    else { return false }
                    
                    return (imageId == latestImageId)
            }
        }
    }
}
