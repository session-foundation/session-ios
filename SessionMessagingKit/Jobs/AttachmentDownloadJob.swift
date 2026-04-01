// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUtilitiesKit
import SessionNetworkingKit

public enum AttachmentDownloadJob: JobExecutor {
    public static var maxFailureCount: Int = 3
    public static var requiresThreadId: Bool = true
    public static let requiresInteractionId: Bool = true
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
        
        /// If we want to allow duplicate downloads (for debugging/testing) then don't bother comparing the jobs
        guard !dependencies[feature: .allowDuplicateDownloads] else {
            return true
        }
        
        /// Prevent multiple downloads for the same attachment from running at the same time
        return !runningJobs.contains { otherJobState in
            guard
                let otherDetailsData: Data = otherJobState.job.details,
                let otherDetails: Details = try? JSONDecoder(using: dependencies)
                    .decode(Details.self, from: otherDetailsData)
            else { return false }
            
            return (details.attachmentId == otherDetails.attachmentId)
        }
    }
    
    public static func run(_ job: Job, using dependencies: Dependencies) async throws -> JobExecutionResult {
        guard
            dependencies[singleton: .appContext].isValid,
            let threadId: String = job.threadId,
            let detailsData: Data = job.details,
            let details: Details = try? JSONDecoder(using: dependencies).decode(Details.self, from: detailsData)
        else { throw JobRunnerError.missingRequiredDetails }
        
        /// Validate and retrieve the attachment state
        let (attachment, alreadyDownloaded): (Attachment, Bool) = try await dependencies[singleton: .storage].write { db -> (Attachment, Bool) in
            guard let attachment: Attachment = try? Attachment.fetchOne(db, id: details.attachmentId) else {
                throw JobRunnerError.missingRequiredDetails
            }
            
            /// Due to the complex nature of jobs and how attachments can be reused it's possible for an
            /// `AttachmentDownloadJob` to get created for an attachment which has already been downloaded or uploaded
            /// so in those cases just succeed immediately
            let fileAlreadyDownloaded: Bool = try {
                guard attachment.state == .downloaded || attachment.state == .uploaded else {
                    return false
                }
                
                /// If the attachment should have been downloaded then check to ensure the file exists (if it doesn't then we should
                /// try to download it again - this will result in the file going into a "failed" state if not which is better than the "file is
                /// downloaded but doesn't exist" state which is handled poorly
                let path: String = try dependencies[singleton: .attachmentManager].path(for: attachment.downloadUrl)
                
                return dependencies[singleton: .fileManager].fileExists(atPath: path)
            }()
            
            guard !fileAlreadyDownloaded else { return (attachment, true) }
            
            /// Update to the 'downloading' state (no need to update the 'attachment' instance)
            try Attachment
                .filter(id: attachment.id)
                .updateAll(db, Attachment.Columns.state.set(to: Attachment.State.downloading))
            db.addAttachmentEvent(
                id: attachment.id,
                messageId: job.interactionId,
                type: .updated(.state(.downloading))
            )
            
            return (attachment, false)
        }
        try Task.checkCancellation()
        
        /// If we've already downloaded the attachment then we can just succeed immediately
        guard !alreadyDownloaded else {
            return .success
        }
        
        /// Since we don't know what type of conversation this download originated with try to retrieve the auth data from the
        /// `CommunityManager` and if that fails we just assume it's for a non-Community conversation
        let maybeAuthMethod: AuthenticationMethod? = await dependencies[singleton: .communityManager]
            .server(threadId: threadId)?
            .authMethod()
        
        let parsedDownloadUrl: ParsedDownloadUrlType
        let response: (temporaryFilePath: String, metadata: FileMetadata)
        
        do {
            parsedDownloadUrl = try Network
                .parsedDownloadUrl(for: attachment.downloadUrl, authMethod: maybeAuthMethod) ?? {
                    throw NetworkError.invalidURL
                }()
            
            switch maybeAuthMethod {
                case let authMethod as Authentication.Community:
                    /// Communities don't support file streaming so we should use the legacy API for these
                    let request: Network.PreparedRequest<Data> = try Network.SOGS.preparedDownload(
                        url: parsedDownloadUrl.url,
                        authMethod: authMethod,
                        using: dependencies
                    )
                    let responseData: Data = try await request.send(using: dependencies)
                    
                    /// Store the encrypted data temporarily
                    let temporaryFilePath: String = dependencies[singleton: .fileManager].temporaryFilePath()
                    try responseData.write(to: URL(fileURLWithPath: temporaryFilePath), options: .atomic)
                    response = (
                        temporaryFilePath,
                        FileMetadata(id: parsedDownloadUrl.fileId, size: UInt64(responseData.count))
                    )
                    
                default:
                    response = try await dependencies[singleton: .network].download(
                        downloadUrl: parsedDownloadUrl.originalUrlString,
                        stallTimeout: Network.fileDownloadTimeout,
                        requestTimeout: Network.fileDownloadTimeout,
                        overallTimeout: Network.fileRequestOverallTimeout,
                        partialMinInterval: Network.fileDownloadMinInterval,
                        desiredPathIndex: details.desiredPathIndex,
                        onProgress: nil
                    )
            }
        }
        catch {
            let targetState: Attachment.State
            let permanentFailure: Bool
            
            switch error {
                /// If we get a 404 then we got a successful response from the server but the attachment doesn't
                /// exist, in this case update the attachment to an "invalid" state so the user doesn't get stuck in
                /// a retry download loop
                case NetworkError.notFound, NetworkError.invalidURL:
                    targetState = .invalid
                    permanentFailure = true
                    
                /// If we got a 400 or a 401 then we want to fail the download in a way that has to be manually retried as it's
                /// likely something else is going on that caused the failure
                case NetworkError.badRequest, NetworkError.unauthorised,
                    StorageServerError.signatureVerificationFailed:
                    targetState = .failedDownload
                    permanentFailure = true
                    
                /// For any other error it's likely either the server is down or something weird just happened with the request
                /// so we want to automatically retry
                default:
                    targetState = .failedDownload
                    permanentFailure = false
            }
            
            /// To prevent the attachment from showing a state of downloading forever, we need to update the attachment
            /// state here based on the type of error that occurred
            ///
            /// **Note:** We **MUST** use the `'with()` function here as it will update the
            /// `isValid` and `duration` values based on the downloaded data and the state
            try? await dependencies[singleton: .storage].write { db in
                _ = try Attachment
                    .filter(id: details.attachmentId)
                    .updateAll(db, Attachment.Columns.state.set(to: targetState))
                db.addAttachmentEvent(
                    id: details.attachmentId,
                    messageId: job.interactionId,
                    type: .updated(.state(targetState))
                )
            }
            
            /// Trigger the failure, but force to a `permanentFailure` if desired
            switch permanentFailure {
                case true: throw JobRunnerError.permanentFailure(error)
                case false: throw error
            }
        }
        
        defer {
            /// Remove the temporary file regardless of the outcome (it'll get recreated if we try again)
            try? dependencies[singleton: .fileManager].removeItem(atPath: response.temporaryFilePath)
        }
        
        try Task.checkCancellation()
        
        /// Decrypt the data if needed
        switch (attachment.encryptionKey, attachment.digest, parsedDownloadUrl.wantsStreamDecryption) {
            case (.some(let key), .some(let digest), false) where !key.isEmpty:
                let ciphertext: Data = try dependencies[singleton: .fileManager].contents(atPath: response.temporaryFilePath)
                let plaintext: Data = try dependencies[singleton: .crypto].tryGenerate(
                    .legacyDecryptAttachment(
                        ciphertext: ciphertext,
                        key: key,
                        digest: digest,
                        unpaddedSize: attachment.byteCount
                    )
                )
                try Task.checkCancellation()
                
                /// Write the decrypted data to disk
                guard try attachment.write(data: plaintext, using: dependencies) else {
                    throw AttachmentDownloadError.failedToSaveFile
                }
                
            case (.some(let key), _, true) where !key.isEmpty:
                guard
                    let downloadUrl: String = attachment.downloadUrl,
                    let finalPath: String = try? dependencies[singleton: .attachmentManager]
                        .path(for: downloadUrl)
                else { throw AttachmentDownloadError.failedToSaveFile }
                
                try dependencies[singleton: .crypto].tryGenerate(
                    .decryptAttachmentToFile(
                        filePath: response.temporaryFilePath,
                        destinationPath: finalPath,
                        key: key
                    )
                )
                
            default:
                /// File is in plaintext so just move it to the destination
                guard
                    let finalPath: String = try? dependencies[singleton: .attachmentManager]
                        .path(for: parsedDownloadUrl.originalUrlString)
                else { throw AttachmentDownloadError.failedToSaveFile }
                
                try dependencies[singleton: .fileManager].moveItem(
                    atPath: response.temporaryFilePath,
                    toPath: finalPath
                )
        }
        try Task.checkCancellation()
        
        /// Update the attachment state
        ///
        /// **Note:** We **MUST** use the `'with()` function here as it will update the
        /// `isValid` and `duration` values based on the downloaded data and the state
        try await dependencies[singleton: .storage].write { db in
            try attachment
                .with(
                    state: .downloaded,
                    creationTimestamp: (dependencies.networkOffsetTimestampMs() / 1000),
                    using: dependencies
                )
                .upserted(db)
            
            db.addAttachmentEvent(
                id: attachment.id,
                messageId: job.interactionId,
                type: .updated(.state(.downloaded))
            )
        }
        
        return .success
    }
}

// MARK: - AttachmentDownloadJob.Details

extension AttachmentDownloadJob {
    public struct Details: Codable {
        public let attachmentId: String
        public let desiredPathIndex: UInt8?
        
        public init(attachmentId: String, desiredPathIndex: UInt8? = nil) {
            self.attachmentId = attachmentId
            self.desiredPathIndex = desiredPathIndex
        }
    }
    
    public struct PriorityData {
        public let attachmentInteractionTimestampMs: [String: Int64]
        public let latestMessageAuthorIds: Set<String>
        public let latestMessageTimestampByAuthorId: [String: Int64]
        
        public init(
            attachmentInteractionTimestampMs: [String: Int64],
            latestMessageAuthorIds: Set<String>,
            latestMessageTimestampByAuthorId: [String: Int64]
        ) {
            self.attachmentInteractionTimestampMs = attachmentInteractionTimestampMs
            self.latestMessageAuthorIds = latestMessageAuthorIds
            self.latestMessageTimestampByAuthorId = latestMessageTimestampByAuthorId
        }
    }
    
    public enum AttachmentDownloadError: LocalizedError {
        case failedToSaveFile

        // stringlint:ignore_contents
        public var errorDescription: String? {
            switch self {
                case .failedToSaveFile: return "Failed to save file"
            }
        }
    }
}
