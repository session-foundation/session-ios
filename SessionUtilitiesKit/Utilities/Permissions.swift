// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import AVFAudio
import AVFoundation

public enum Permissions {
    
    public enum Status {
        case denied
        case granted
        case undetermined
        case unknown
    }
    
    public static var microphone: Status {
        if #available(iOSApplicationExtension 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
                case .undetermined:
                    return .undetermined
                case .denied:
                    return .denied
                case .granted:
                    return .granted
                @unknown default:
                    return .unknown
            }
        } else {
            switch AVAudioSession.sharedInstance().recordPermission {
                case .undetermined:
                    return .undetermined
                case .denied:
                    return .denied
                case .granted:
                    return .granted
                @unknown default:
                    return .unknown
            }
        }
    }
    
    public static var camera: Status {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .notDetermined:
                return .undetermined
            case .restricted, .denied:
                return .denied
            case .authorized:
                return .granted
            @unknown default:
                return .unknown
        }
    }
}
