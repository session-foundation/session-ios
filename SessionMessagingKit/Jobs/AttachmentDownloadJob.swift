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
    
    public static func canStart(
        jobState: JobState,
        alongside runningJobs: [JobState],
        using dependencies: Dependencies
    ) -> Bool {
        guard
            let detailsData: Data = jobState.job.details,
            let details: Details = try? JSONDecoder(using: dependencies)
                .decode(Details.self, from: detailsData)
        else { return true }    /// If we can't get the details then just run the job (it'll fail permanently)
        
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
        let (attachment, alreadyDownloaded): (Attachment, Bool) = try await dependencies[singleton: .storage].writeAsync { db -> (Attachment, Bool) in
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
        
        guard let downloadUrl: URL = attachment.downloadUrl.map({ URL(string: $0) }) else {
            throw AttachmentDownloadError.invalidUrl
        }
        
        /// Download the attachment data
        let maybeAuthMethod: AuthenticationMethod? = try await dependencies[singleton: .storage].readAsync { db in
            try? Authentication.with(
                db,
                threadId: threadId,
                threadVariant: .community,
                using: dependencies
            )
        }
        
        let request: Network.PreparedRequest<Data>
        
        switch maybeAuthMethod {
            case let authMethod as Authentication.Community:
                request = try Network.SOGS.preparedDownload(
                    url: downloadUrl,
                    roomToken: authMethod.roomToken,
                    authMethod: authMethod,
                    using: dependencies
                )
                
            default:
                request = try Network.FileServer.preparedDownload(
                    url: downloadUrl,
                    using: dependencies
                )
        }
        
        // FIXME: Make this async/await when the refactored networking is merged
        let response: Data
        
        do {
            response = try await request
                .send(using: dependencies)
                .values
                .first(where: { _ in true })?.1 ?? { throw AttachmentError.downloadFailed }()
        }
        catch {
            let targetState: Attachment.State
            let permanentFailure: Bool
            
            switch error {
                /// If we get a 404 then we got a successful response from the server but the attachment doesn't
                /// exist, in this case update the attachment to an "invalid" state so the user doesn't get stuck in
                /// a retry download loop
                case NetworkError.notFound:
                    targetState = .invalid
                    permanentFailure = true
                    
                /// If we got a 400 or a 401 then we want to fail the download in a way that has to be manually retried as it's
                /// likely something else is going on that caused the failure
                case NetworkError.badRequest, NetworkError.unauthorised,
                    SnodeAPIError.signatureVerificationFailed:
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
            try? await dependencies[singleton: .storage].writeAsync { db in
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
        try Task.checkCancellation()
                
        /// Store the encrypted data temporarily
        let temporaryFilePath: String = dependencies[singleton: .fileManager].temporaryFilePath()
        try response.write(to: URL(fileURLWithPath: temporaryFilePath), options: .atomic)
        defer {
            /// Remove the temporary file regardless of the outcome (it'll get recreated if we try again)
            try? dependencies[singleton: .fileManager].removeItem(atPath: temporaryFilePath)
        }
        
        /// Decrypt the data if needed
        let plaintext: Data
        let usesDeterministicEncryption: Bool = Network.FileServer
            .usesDeterministicEncryption(attachment.downloadUrl)
        
        switch (attachment.encryptionKey, attachment.digest, usesDeterministicEncryption) {
            case (.some(let key), .some(let digest), false) where !key.isEmpty:
                plaintext = try dependencies[singleton: .crypto].tryGenerate(
                    .legacyDecryptAttachment(
                        ciphertext: response,
                        key: key,
                        digest: digest,
                        unpaddedSize: attachment.byteCount
                    )
                )
                
            case (.some(let key), _, true) where !key.isEmpty:
                plaintext = try dependencies[singleton: .crypto].tryGenerate(
                    .decryptAttachment(
                        ciphertext: response,
                        key: key
                    )
                )
                
            default: plaintext = response
        }
        try Task.checkCancellation()
        
        /// Write the decrypted data to disk
        guard try attachment.write(data: plaintext, using: dependencies) else {
            throw AttachmentDownloadError.failedToSaveFile
        }
        try Task.checkCancellation()
        
        /// Update the attachment state
        ///
        /// **Note:** We **MUST** use the `'with()` function here as it will update the
        /// `isValid` and `duration` values based on the downloaded data and the state
        try await dependencies[singleton: .storage].writeAsync { db in
            try attachment
                .with(
                    state: .downloaded,
                    creationTimestamp: (dependencies[cache: .snodeAPI].currentOffsetTimestampMs() / 1000),
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
        
        public init(attachmentId: String) {
            self.attachmentId = attachmentId
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
        case invalidUrl

        // stringlint:ignore_contents
        public var errorDescription: String? {
            switch self {
                case .failedToSaveFile: return "Failed to save file"
                case .invalidUrl: return "Invalid file URL"
            }
        }
    }
}
