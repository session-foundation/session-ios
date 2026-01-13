// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import AVFoundation
import Photos
import UserNotifications

public enum Permissions {
    public enum Variant: String {
        case microphone
        case camera
        case photoLibrary
        case notifications
        case localNetwork
    }
    
    public enum Status: Sendable, Equatable, CustomStringConvertible {
        case denied
        case granted
        case undetermined
        case restricted
        case unknown
        
        // stringlint:ignore_contents
        public var description: String {
            switch self {
                case .denied: return "Denied"
                case .granted: return "Granted"
                case .undetermined: return "Not Determined"
                case .restricted: return "Restricted"
                case .unknown: return "Unknown"
            }
        }
    }
    
    // MARK: - Synchronous Permissions
    
    public static var microphone: Status {
        if #available(iOSApplicationExtension 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
                case .undetermined: return .undetermined
                case .denied: return .denied
                case .granted: return .granted
                @unknown default: return .unknown
            }
        } else {
            switch AVAudioSession.sharedInstance().recordPermission {
                case .undetermined: return .undetermined
                case .denied: return .denied
                case .granted: return .granted
                @unknown default: return .unknown
            }
        }
    }
    
    public static var camera: Status {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .notDetermined: return .undetermined
            case .restricted: return .restricted
            case .denied: return .denied
            case .authorized: return .granted
            @unknown default: return .unknown
        }
    }
    
    public static var photoLibrary: Status {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
            case .notDetermined: return .undetermined
            case .restricted: return .restricted
            case .denied: return .denied
            case .authorized, .limited: return .granted
            @unknown default: return .unknown
        }
    }
    
    // MARK: - Async Permissions
        
    public static func notifications() async -> Status {
        let settings: UNNotificationSettings = await UNUserNotificationCenter.current().notificationSettings()
        
        switch settings.authorizationStatus {
            case .notDetermined: return .undetermined
            case .denied: return .denied
            case .authorized, .provisional, .ephemeral: return .granted
            @unknown default: return .unknown
        }
    }
    
    // MARK: - Batch Check
        
    public struct Summary: CustomStringConvertible {
        public let microphone: Status
        public let camera: Status
        public let photoLibrary: Status
        public let notifications: Status
        
        public var description: String {
            """
            Microphone: \(microphone)
            Camera: \(camera)
            Photo Library: \(photoLibrary)
            Notifications: \(notifications)
            """
        }
    }
    
    public static func summary() async -> Summary {
        return Summary(
            microphone: microphone,
            camera: camera,
            photoLibrary: photoLibrary,
            notifications: await notifications()
        )
    }
}

// MARK: - Observations

public extension ObservableKey {
    static func permission(_ key: Permissions.Variant) -> ObservableKey {
        ObservableKey("permission-\(key.rawValue)", .permission)
    }
}

public extension GenericObservableKey {
    static let permission: GenericObservableKey = "permission"
}
