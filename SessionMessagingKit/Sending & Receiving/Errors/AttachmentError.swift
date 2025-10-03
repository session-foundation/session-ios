// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUIKit

public enum AttachmentError: Error, CustomStringConvertible {
    case invalidStartState
    case noAttachment
    case notUploaded
    case encryptionFailed
    case uploadIsStillPendingDownload
    case uploadFailed
    
    case missingData
    case fileSizeTooLarge
    case invalidData
    case couldNotParseImage
    case couldNotConvertToJpeg
    case couldNotConvertToMpeg4
    case couldNotRemoveMetadata
    case invalidFileFormat
    case couldNotResizeImage
    case invalidAttachmentSource
    case invalidPath
    case writeFailed
    
    case invalidMediaSource
    case invalidDimensions
    case invalidImageData
    
    public var description: String {
        switch self {
            case .invalidStartState: return "Cannot upload an attachment in this state."
            case .noAttachment: return "No such attachment."
            case .notUploaded: return "Attachment not uploaded."
            case .encryptionFailed: return "Couldn't encrypt file."
            case .uploadIsStillPendingDownload: return "Upload is still pending download."
            case .uploadFailed: return "Upload failed."
            case .invalidAttachmentSource: return "Invalid attachment source."
            case .invalidPath: return "Failed to generate a valid path."
            case .writeFailed: return "Failed to write to disk."
            
            case .invalidMediaSource: return "Invalid media source."
            case .invalidDimensions: return "Invalid dimensions."
                
            case .fileSizeTooLarge: return "attachmentsErrorSize".localized()
            case .invalidData, .missingData, .invalidFileFormat, .invalidImageData:
                return "attachmentsErrorNotSupported".localized()
                
            case .couldNotConvertToJpeg, .couldNotParseImage, .couldNotConvertToMpeg4, .couldNotResizeImage:
                return "attachmentsErrorOpen".localized()
                
            case .couldNotRemoveMetadata:
                return "attachmentsImageErrorMetadata".localized()
        }
    }
}
