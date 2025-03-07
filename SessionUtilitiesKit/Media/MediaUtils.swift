// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import AVFoundation

// MARK: - Log.Category

public extension Log.Category {
    static let media: Log.Category = .create("MediaUtils", defaultLevel: .warn)
}

// MARK: - MediaError

public enum MediaError: Error {
    case failure(description: String)
}

// MARK: - MediaUtils

public enum MediaUtils {
    public static var maxFileSizeAnimatedImage: UInt { SNUtilitiesKit.maxFileSize }
    public static var maxFileSizeImage: UInt { SNUtilitiesKit.maxFileSize }
    public static var maxFileSizeVideo: UInt { SNUtilitiesKit.maxFileSize }
    public static var maxFileSizeAudio: UInt { SNUtilitiesKit.maxFileSize }
    public static var maxFileSizeGeneric: UInt { SNUtilitiesKit.maxFileSize }

    public static let maxAnimatedImageDimensions: UInt = 1 * 1024
    public static let maxStillImageDimensions: UInt = 8 * 1024
    public static let maxVideoDimensions: CGFloat = 3 * 1024
    
    public static func thumbnail(forImageAtPath path: String, maxDimension: CGFloat, type: String, using dependencies: Dependencies) throws -> UIImage {
        Log.verbose(.media, "Thumbnailing image: \(path)")

        guard dependencies[singleton: .fileManager].fileExists(atPath: path) else {
            throw MediaError.failure(description: "Media file missing.")
        }
        guard Data.isValidImage(at: path, type: UTType(sessionMimeType: type), using: dependencies) else {
            throw MediaError.failure(description: "Invalid image.")
        }
        guard let originalImage = UIImage(contentsOfFile: path) else {
            throw MediaError.failure(description: "Could not load original image.")
        }
        guard let thumbnailImage = originalImage.resized(maxDimensionPoints: maxDimension) else {
            throw MediaError.failure(description: "Could not thumbnail image.")
        }
        return thumbnailImage
    }

    public static func thumbnail(forVideoAtPath path: String, maxDimension: CGFloat, using dependencies: Dependencies) throws -> UIImage {
        Log.verbose(.media, "Thumbnailing video: \(path)")

        guard isVideoOfValidContentTypeAndSize(path: path, using: dependencies) else {
            throw MediaError.failure(description: "Media file has missing or invalid length.")
        }

        let maxSize = CGSize(width: maxDimension, height: maxDimension)
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url, options: nil)
        guard isValidVideo(asset: asset) else {
            throw MediaError.failure(description: "Invalid video.")
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = maxSize
        generator.appliesPreferredTrackTransform = true
        let time: CMTime = CMTimeMake(value: 1, timescale: 60)
        let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
        let image = UIImage(cgImage: cgImage)
        return image
    }

    public static func isValidVideo(path: String, using dependencies: Dependencies) -> Bool {
        guard isVideoOfValidContentTypeAndSize(path: path, using: dependencies) else {
            Log.error(.media, "Media file has missing or invalid length.")
            return false
        }

        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url, options: nil)
        return isValidVideo(asset: asset)
    }

    private static func isVideoOfValidContentTypeAndSize(path: String, using dependencies: Dependencies) -> Bool {
        guard dependencies[singleton: .fileManager].fileExists(atPath: path) else {
            Log.error(.media, "Media file missing.")
            return false
        }
        let fileExtension = URL(fileURLWithPath: path).pathExtension
        guard let contentType: String = UTType.sessionMimeType(for: fileExtension) else {
            Log.error(.media, "Media file has unknown content type.")
            return false
        }
        guard UTType.isVideo(contentType) else {
            Log.error(.media, "Media file has invalid content type.")
            return false
        }

        guard let fileSize: UInt64 = dependencies[singleton: .fileManager].fileSize(of: path) else {
            Log.error(.media, "Media file has unknown length.")
            return false
        }
        return UInt(fileSize) <= SNUtilitiesKit.maxFileSize
    }

    private static func isValidVideo(asset: AVURLAsset) -> Bool {
        var maxTrackSize = CGSize.zero
        for track: AVAssetTrack in asset.tracks(withMediaType: .video) {
            let trackSize: CGSize = track.naturalSize
            maxTrackSize.width = max(maxTrackSize.width, trackSize.width)
            maxTrackSize.height = max(maxTrackSize.height, trackSize.height)
        }
        if maxTrackSize.width < 1.0 || maxTrackSize.height < 1.0 {
            Log.error(.media, "Invalid video size: \(maxTrackSize)")
            return false
        }
        if maxTrackSize.width > maxVideoDimensions || maxTrackSize.height > maxVideoDimensions {
            Log.error(.media, "Invalid video dimensions: \(maxTrackSize)")
            return false
        }
        return true
    }
}
