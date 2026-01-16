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
    case legacyEncryptionFailed
    case legacyDecryptionFailed
    case notEncrypted
    case uploadFailed
    case downloadFailed
    
    case missingData
    case fileSizeTooLarge
    case invalidData
    case couldNotParseImage
    case couldNotConvert
    case couldNotConvertToJpeg
    case couldNotConvertToMpeg4
    case couldNotConvertToWebP
    case couldNotRemoveMetadata
    case invalidFileFormat
    case couldNotResizeImage
    case invalidAttachmentSource
    case invalidPath
    case writeFailed
    case downloadNoLongerValid
    case databaseChangesFailed
    case conversionTimeout
    case conversionResultedInLargerFile
    
    case invalidMediaSource
    case invalidDimensions
    case invalidDuration
    case invalidImageData
    
    public var description: String {
        switch self {
            case .invalidStartState: return "Cannot upload an attachment in this state."
            case .noAttachment: return "No such attachment."
            case .notUploaded: return "Attachment not uploaded."
            case .encryptionFailed: return "Couldn't encrypt file."
            case .legacyEncryptionFailed: return "Couldn't encrypt file (legacy)."
            case .legacyDecryptionFailed: return "Couldn't decrypt file (legacy)."
            case .notEncrypted: return "File not encrypted."
            case .uploadFailed: return "Upload failed."
            case .downloadFailed: return "Download failed."
            case .invalidAttachmentSource: return "Invalid attachment source."
            case .invalidPath: return "Failed to generate a valid path."
            case .writeFailed: return "Failed to write to disk."
            case .downloadNoLongerValid: return "Download is no longer valid."
            case .databaseChangesFailed: return "Database changes failed."
            case .conversionTimeout: return "Conversion timed out."
            case .conversionResultedInLargerFile: return "Conversion resulted in a larger file."
            
            case .invalidMediaSource: return "Invalid media source."
            case .invalidDimensions: return "Invalid dimensions."
            case .invalidDuration: return "Invalid duration."
                
            case .fileSizeTooLarge: return "attachmentsErrorSize".localized()
            case .invalidData, .missingData, .invalidFileFormat, .invalidImageData:
                return "attachmentsErrorNotSupported".localized()
                
            case .couldNotConvert, .couldNotConvertToJpeg, .couldNotParseImage, .couldNotConvertToMpeg4,
                .couldNotConvertToWebP, .couldNotResizeImage:
                return "attachmentsErrorOpen".localized()
                
            case .couldNotRemoveMetadata:
                return "attachmentsImageErrorMetadata".localized()
        }
    }
}
