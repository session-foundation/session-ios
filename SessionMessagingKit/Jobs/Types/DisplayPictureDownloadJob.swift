// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import GRDB
import SessionUtilitiesKit
import SessionSnodeKit

public enum DisplayPictureDownloadJob: JobExecutor {
    public static var maxFailureCount: Int = 1
    public static var requiresThreadId: Bool = false
    public static var requiresInteractionId: Bool = false
    
    public static func run(
        _ job: Job,
        queue: DispatchQueue,
        success: @escaping (Job, Bool, Dependencies) -> (),
        failure: @escaping (Job, Error?, Bool, Dependencies) -> (),
        deferred: @escaping (Job, Dependencies) -> (),
        using dependencies: Dependencies
    ) {
        guard
            let detailsData: Data = job.details,
            let details: Details = try? JSONDecoder(using: dependencies).decode(Details.self, from: detailsData),
            let preparedDownload: HTTP.PreparedRequest<Data> = try? {
                switch details.target {
                    case .profile(_, let url, let encryptionKey):
                        guard
                            !url.isEmpty,
                            let fileId: String = Attachment.fileId(for: url),
                            encryptionKey.count == ProfileManager.avatarAES256KeyByteLength
                        else { return nil }
                        
                        return try FileServerAPI.preparedDownload(
                            fileId: fileId,
                            useOldServer: url.contains(FileServerAPI.oldServer),
                            using: dependencies
                        )
                }
            }()
        else {
            SNLog("[DisplayPictureDownloadJob] Failing due to missing details")
            failure(job, JobRunnerError.missingRequiredDetails, true, dependencies)
            return
        }
            
        let fileName: String = UUID().uuidString.appendingFileExtension("jpg")
        let filePath: String = ProfileManager.profileAvatarFilepath(filename: fileName)
        
        preparedDownload
            .send(using: dependencies)
            .subscribe(on: DispatchQueue.global(qos: .background), using: dependencies)
            .receive(on: DispatchQueue.global(qos: .background), using: dependencies)
            .sinkUntilComplete(
                receiveCompletion: { result in
                    switch result {
                        case .finished: success(job, false, dependencies)
                        case .failure(let error): failure(job, error, true, dependencies)
                    }
                },
                receiveValue: { _, data in
                    switch details.target {
                        case .profile(let id, let url, let encryptionKey):
                            guard let latestProfile: Profile = dependencies[singleton: .storage].read({ db in try Profile.fetchOne(db, id: id) }) else {
                                return
                            }
                            
                            // Check to make sure this download matches the profile settings
                            guard
                                details.timestamp >= (latestProfile.lastProfilePictureUpdate ?? 0) || (
                                    encryptionKey == latestProfile.profileEncryptionKey &&
                                    url == latestProfile.profilePictureUrl
                                )
                            else { return }
                            
                            guard let decryptedData: Data = ProfileManager.decryptData(data: data, key: encryptionKey) else {
                                SNLog("[DisplayPictureDownloadJob] Failed to decrypt display picture for \(id)")
                                failure(job, ProfileManagerError.avatarWriteFailed, true, dependencies)
                                return
                            }
                            
                            try? decryptedData.write(to: URL(fileURLWithPath: filePath), options: [.atomic])
                            
                            guard UIImage(contentsOfFile: filePath) != nil else {
                                SNLog("[DisplayPictureDownloadJob] Failed to load display picture for \(id)")
                                failure(job, ProfileManagerError.avatarWriteFailed, true, dependencies)
                                return
                            }
                            
                            // Update the cache first (in case the DBWrite thread is blocked, this way other threads
                            // can retrieve from the cache and avoid triggering a download)
                            ProfileManager.cache(fileName: fileName, avatarData: decryptedData)
                            
                            // Store the updated 'profilePictureFileName'
                            dependencies[singleton: .storage].write { db in
                                _ = try? Profile
                                    .filter(id: id)
                                    .updateAllAndConfig(
                                        db,
                                        Profile.Columns.profilePictureUrl.set(to: url),
                                        Profile.Columns.profileEncryptionKey.set(to: encryptionKey),
                                        Profile.Columns.profilePictureFileName.set(to: fileName),
                                        Profile.Columns.lastProfilePictureUpdate.set(to: details.timestamp)
                                    )
                            }
                    }
                }
            )
    }
}

// MARK: - DisplayPictureDownloadJob.Details

extension DisplayPictureDownloadJob {
    public enum Target: Codable, Hashable {
        case profile(id: String, url: String, encryptionKey: Data)
    }
    
    public struct Details: Codable, Hashable {
        public let target: Target
        public let timestamp: TimeInterval
        
        public init?(target: Target, timestamp: TimeInterval) {
            switch target {
                case .profile(_, let url, let encryptionKey):
                    guard
                        !url.isEmpty,
                        Attachment.fileId(for: url) != nil,
                        encryptionKey.count == ProfileManager.avatarAES256KeyByteLength
                    else { return nil }
                    
                    break
            }
            
            self.target = target
            self.timestamp = timestamp
        }
        
        public init?(profile: Profile) {
            guard
                let url: String = profile.profilePictureUrl,
                let key: Data = profile.profileEncryptionKey,
                let details: Details = Details(
                    target: .profile(id: profile.id, url: url, encryptionKey: key),
                    timestamp: (profile.lastProfilePictureUpdate ?? 0)
                )
            else { return nil }
            
            self = details
        }
    }
}

