// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import AudioToolbox
import GRDB
import DifferenceKit
import SessionUtilitiesKit

// MARK: - Log.Category

private extension Log.Category {
    static let cat: Log.Category = .create("Preferences.Sound", defaultLevel: .warn)
}

// MARK: - Preferences

public extension Preferences {
    enum Sound: Int, Codable, DatabaseValueConvertible, EnumIntSetting, Differentiable {
        public static var defaultiOSIncomingRingtone: Sound = .opening
        public static var defaultNotificationSound: Sound = .note
        
        // Don't store too many sounds in memory (Most users will only use 1 or 2 sounds anyway)
        private static let maxCachedSounds: Int = 4
        @ThreadSafeObject private static var cachedSystemSounds: [String: (url: URL?, soundId: SystemSoundID)] = [:]
        @ThreadSafeObject private static var cachedSystemSoundOrder: [String] = []
        
        // Values
        
        case `default`
        
        // Notification Sounds
        case aurora = 1000
        case bamboo
        case chord
        case circles
        case complete
        case hello
        case input
        case keys
        case note
        case popcorn
        case pulse
        case synth
        case signalClassic
        
        // Ringtone Sounds
        case opening = 2000
        
        // Calls
        case callConnecting = 3000
        case callOutboundRinging
        case callBusy
        case callFailure
        
        // Other
        case messageSent = 4000
        case none
        
        public static var notificationSounds: [Sound] {
            return [
                // None and Note (default) should be first.
                .none,
                .note,
                
                .aurora,
                .bamboo,
                .chord,
                .circles,
                .complete,
                .hello,
                .input,
                .keys,
                .popcorn,
                .pulse,
                .synth
            ]
        }
        
        public var displayName: String {
            // TODO: Should we localize these sound names?
            switch self {
                case .`default`: return ""
                
                // Notification Sounds
                case .aurora: return "Aurora"
                case .bamboo: return "Bamboo"
                case .chord: return "Chord"
                case .circles: return "Circles"
                case .complete: return "Complete"
                case .hello: return "Hello"
                case .input: return "Input"
                case .keys: return "Keys"
                case .note: return "Note"
                case .popcorn: return "Popcorn"
                case .pulse: return "Pulse"
                case .synth: return "Synth"
                case .signalClassic: return "Signal Classic"
                
                // Ringtone Sounds
                case .opening: return "Opening"
                
                // Calls
                case .callConnecting: return "Call Connecting"
                case .callOutboundRinging: return "Call Outboung Ringing"
                case .callBusy: return "Call Busy"
                case .callFailure: return "Call Failure"
                
                // Other
                case .messageSent: return "Message Sent"
                case .none: return "none".localized()
            }
        }
        
        // MARK: - Functions
        
        // stringlint:ignore_contents
        public func filename(quiet: Bool = false) -> String? {
            switch self {
                case .`default`: return ""
                
                // Notification Sounds
                case .aurora: return (quiet ? "aurora-quiet.aifc" : "aurora.aifc")
                case .bamboo: return (quiet ? "bamboo-quiet.aifc" : "bamboo.aifc")
                case .chord: return (quiet ? "chord-quiet.aifc" : "chord.aifc")
                case .circles: return (quiet ? "circles-quiet.aifc" : "circles.aifc")
                case .complete: return (quiet ? "complete-quiet.aifc" : "complete.aifc")
                case .hello: return (quiet ? "hello-quiet.aifc" : "hello.aifc")
                case .input: return (quiet ? "input-quiet.aifc" : "input.aifc")
                case .keys: return (quiet ? "keys-quiet.aifc" : "keys.aifc")
                case .note: return (quiet ? "note-quiet.aifc" : "note.aifc")
                case .popcorn: return (quiet ? "popcorn-quiet.aifc" : "popcorn.aifc")
                case .pulse: return (quiet ? "pulse-quiet.aifc" : "pulse.aifc")
                case .synth: return (quiet ? "synth-quiet.aifc" : "synth.aifc")
                case .signalClassic: return (quiet ? "classic-quiet.aifc" : "classic.aifc")
                
                // Ringtone Sounds
                case .opening: return "Opening.m4r"
                
                // Calls
                case .callConnecting: return "ringback_tone_ansi.caf"
                case .callOutboundRinging: return "ringback_tone_ansi.caf"
                case .callBusy: return "busy_tone_ansi.caf"
                case .callFailure: return "end_call_tone_cept.caf"
                
                // Other
                case .messageSent: return "message_sent.aiff"
                case .none: return "silence.aiff"
            }
        }
        
        public func soundUrl(quiet: Bool = false) -> URL? {
            guard let filename: String = filename(quiet: quiet) else { return nil }
            
            let url: URL = URL(fileURLWithPath: filename)
            
            return Bundle.main.url(
                forResource: url.deletingPathExtension().path,
                withExtension: url.pathExtension
            )
        }
        
        public func notificationSound(isQuiet: Bool) -> UNNotificationSound {
            guard let filename: String = filename(quiet: isQuiet) else {
                Log.warn(.cat, "Filename was unexpectedly nil")
                return UNNotificationSound.default
            }
            
            return UNNotificationSound(named: UNNotificationSoundName(rawValue: filename))
        }
        
        public static func systemSoundId(for sound: Sound, quiet: Bool) -> SystemSoundID {
            let cacheKey: String = "\(sound.rawValue):\(quiet ? 1 : 0)"
            
            if let cachedSound: SystemSoundID = cachedSystemSounds[cacheKey]?.soundId {
                return cachedSound
            }
            
            let systemSound: (url: URL?, soundId: SystemSoundID) = (
                url: sound.soundUrl(quiet: quiet),
                soundId: SystemSoundID()
            )
            
            _cachedSystemSounds.performUpdate { cache in
                var updatedCache: [String: (url: URL?, soundId: SystemSoundID)] = cache
                
                _cachedSystemSoundOrder.performUpdate { order in
                    var updatedOrder: [String] = order
                    
                    if order.count > Sound.maxCachedSounds {
                        updatedCache.removeValue(forKey: order[0])
                        updatedOrder.remove(at: 0)
                    }
                    
                    return updatedOrder.appending(cacheKey)
                }
                
                return updatedCache.setting(cacheKey, systemSound)
            }
            
            return systemSound.soundId
        }
        
        // MARK: - AudioPlayer
        
        public static func audioPlayer(for sound: Sound, behavior: OWSAudioBehavior) -> OWSAudioPlayer? {
            guard let soundUrl: URL = sound.soundUrl(quiet: false) else { return nil }
            
            let player = OWSAudioPlayer(mediaUrl: soundUrl, audioBehavior: behavior)
            
            // These two cases should loop
            if sound == .callConnecting || sound == .callOutboundRinging {
                player.isLooping = true
            }
            
            return player
        }
    }
}
