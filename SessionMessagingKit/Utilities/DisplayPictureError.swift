// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

public enum DisplayPictureError: Error, Equatable, CustomStringConvertible {
    case imageTooLarge
    case writeFailed
    case loadFailed
    case imageProcessingFailed
    case databaseChangesFailed
    case encryptionFailed
    case uploadFailed
    case uploadMaxFileSizeExceeded
    case invalidCall
    case invalidPath
    case alreadyDownloaded(URL?)
    case updateNoLongerValid
    case notEncrypted
    
    public var description: String {
        switch self {
            case .imageTooLarge: return "Display picture too large."
            case .writeFailed: return "Display picture write failed."
            case .loadFailed: return "Display picture load failed."
            case .imageProcessingFailed: return "Display picture processing failed."
            case .databaseChangesFailed: return "Failed to save display picture to database."
            case .encryptionFailed: return "Display picture encryption failed."
            case .uploadFailed: return "Display picture upload failed."
            case .uploadMaxFileSizeExceeded: return "Maximum file size exceeded."
            case .invalidCall: return "Attempted to remove display picture using the wrong method."
            case .invalidPath: return "Failed to generate a valid path."
            case .alreadyDownloaded: return "Display picture already downloaded."
            case .updateNoLongerValid: return "Display picture update no longer valid."
            case .notEncrypted: return "Display picture not encrypted."
        }
    }
}
