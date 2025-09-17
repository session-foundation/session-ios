// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionNetworkingKit
import SessionUtilitiesKit

// MARK: - AttachmentUploader

public final class AttachmentUploader {
    private enum Destination {
        case fileServer
        case community(roomToken: String, server: String)
        
        var shouldEncrypt: Bool {
            switch self {
                case .fileServer: return true
                case .community: return false
            }
        }
    }
    
    public static func prepare(attachments: [SignalAttachment], using dependencies: Dependencies) -> [Attachment] {
        return attachments.compactMap { signalAttachment in
            Attachment(
                variant: (signalAttachment.isVoiceMessage ?
                    .voiceMessage :
                    .standard
                ),
                contentType: signalAttachment.mimeType,
                dataSource: signalAttachment.dataSource,
                sourceFilename: signalAttachment.sourceFilename,
                caption: signalAttachment.captionText,
                using: dependencies
            )
        }
    }
    
    public static func process(
        _ db: ObservingDatabase,
        attachments: [Attachment]?,
        for interactionId: Int64?
    ) throws {
        guard
            let attachments: [Attachment] = attachments,
            let interactionId: Int64 = interactionId
        else { return }
                
        try attachments
            .enumerated()
            .forEach { index, attachment in
                let interactionAttachment: InteractionAttachment = InteractionAttachment(
                    albumIndex: index,
                    interactionId: interactionId,
                    attachmentId: attachment.id
                )
                
                try attachment.insert(db)
                try interactionAttachment.insert(db)
            }
    }
    
    public static func preparedUpload(
        attachment: Attachment,
        logCategory cat: Log.Category?,
        authMethod: AuthenticationMethod,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<(attachment: Attachment, fileId: String)> {
        typealias UploadInfo = (
            attachment: Attachment,
            preparedRequest: Network.PreparedRequest<FileUploadResponse>,
            encryptionKey: Data?,
            digest: Data?
        )
        typealias EncryptionData = (ciphertext: Data, encryptionKey: Data, digest: Data)
        
        // Generate the correct upload info based on the state of the attachment
        let destination: AttachmentUploader.Destination = {
            switch authMethod {
                case let auth as Authentication.community:
                    return .community(roomToken: auth.roomToken, server: auth.server)
                
                default: return .fileServer
            }
        }()
        let uploadInfo: UploadInfo = try {
            let endpoint: (any EndpointType) = {
                switch destination {
                    case .fileServer: return Network.FileServer.Endpoint.file
                    case .community(let roomToken, _): return Network.SOGS.Endpoint.roomFile(roomToken)
                }
            }()
            
            // This can occur if an AttachmentUploadJob was explicitly created for a message
            // dependant on the attachment being uploaded (in this case the attachment has
            // already been uploaded so just succeed)
            if attachment.state == .uploaded, let fileId: String = Network.FileServer.fileId(for: attachment.downloadUrl) {
                return (
                    attachment,
                    try Network.PreparedRequest<FileUploadResponse>.cached(
                        FileUploadResponse(id: fileId),
                        endpoint: endpoint,
                        using: dependencies
                    ),
                    attachment.encryptionKey,
                    attachment.digest
                )
            }
            
            // If the attachment is a downloaded attachment, check if it came from
            // the server and if so just succeed immediately (no use re-uploading
            // an attachment that is already present on the server) - or if we want
            // it to be encrypted and it's not then encrypt it
            //
            // Note: The most common cases for this will be for LinkPreviews or Quotes
            if
                attachment.state == .downloaded,
                let fileId: String = Network.FileServer.fileId(for: attachment.downloadUrl),
                (
                    !destination.shouldEncrypt || (
                        attachment.encryptionKey != nil &&
                        attachment.digest != nil
                    )
                )
            {
                return (
                    attachment,
                    try Network.PreparedRequest.cached(
                        FileUploadResponse(id: fileId),
                        endpoint: endpoint,
                        using: dependencies
                    ),
                    attachment.encryptionKey,
                    attachment.digest
                )
            }
            
            // Get the raw attachment data
            guard let rawData: Data = try? attachment.readDataFromFile(using: dependencies) else {
                Log.error([cat].compactMap { $0 }, "Couldn't read attachment from disk.")
                throw AttachmentError.noAttachment
            }
            
            // Encrypt the attachment if needed
            var finalData: Data = rawData
            var encryptionKey: Data?
            var digest: Data?
            
            if destination.shouldEncrypt {
                guard
                    let result: EncryptionData = dependencies[singleton: .crypto].generate(
                        .encryptAttachment(plaintext: rawData)
                    )
                else {
                    Log.error([cat].compactMap { $0 }, "Couldn't encrypt attachment.")
                    throw AttachmentError.encryptionFailed
                }
                
                finalData = result.ciphertext
                encryptionKey = result.encryptionKey
                digest = result.digest
            }
                
            // Ensure the file size is smaller than our upload limit
            Log.info([cat].compactMap { $0 }, "File size: \(finalData.count) bytes.")
            guard finalData.count <= Network.maxFileSize else { throw NetworkError.maxFileSizeExceeded }
            
            // Generate the request
            switch destination {
                case .fileServer:
                    return (
                        attachment,
                        try Network.FileServer.preparedUpload(data: finalData, using: dependencies),
                        encryptionKey,
                        digest
                    )
                
                case .community(let roomToken, _):
                    return (
                        attachment,
                        try Network.SOGS.preparedUpload(
                            data: finalData,
                            roomToken: roomToken,
                            authMethod: authMethod,
                            using: dependencies
                        ),
                        encryptionKey,
                        digest
                    )
            }
        }()
        
        return uploadInfo.preparedRequest.map { _, response in
            /// Generate the updated attachment info
            ///
            /// **Note:** We **MUST** use the `.with` function here to ensure the `isValid` flag is
            /// updated correctly
            let updatedAttachment: Attachment = uploadInfo.attachment
                .with(
                    serverId: response.id,
                    state: .uploaded,
                    creationTimestamp: (
                        uploadInfo.attachment.creationTimestamp ??
                        (dependencies[cache: .storageServer].currentOffsetTimestampMs() / 1000)
                    ),
                    downloadUrl: {
                        let isPlaceholderUploadUrl: Bool = dependencies[singleton: .attachmentManager]
                            .isPlaceholderUploadUrl(uploadInfo.attachment.downloadUrl)
                        
                        switch (uploadInfo.attachment.downloadUrl, isPlaceholderUploadUrl, destination) {
                            case (.some(let downloadUrl), false, _): return downloadUrl
                            case (_, _, .fileServer):
                                return Network.FileServer.downloadUrlString(for: response.id)
                                
                            case (_, _, .community(let roomToken, let server)):
                                return Network.SOGS.downloadUrlString(
                                    for: response.id,
                                    server: server,
                                    roomToken: roomToken
                                )
                        }
                    }(),
                    encryptionKey: uploadInfo.encryptionKey,
                    digest: uploadInfo.digest,
                    using: dependencies
                )
            
            return (updatedAttachment, response.id)
        }
    }
}
