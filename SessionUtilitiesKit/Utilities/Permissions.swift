// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import AVFAudio

public enum Permissions {
    public static var hasMicrophonePermission: Bool {
        if #available(iOSApplicationExtension 17.0, *) {
            AVAudioApplication.shared.recordPermission == .granted
        } else {
            AVAudioSession.sharedInstance().recordPermission == .granted
        }
    }
}
