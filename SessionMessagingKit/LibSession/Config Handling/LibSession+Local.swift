// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionUIKit
import SessionUtilitiesKit

// MARK: - State Observation

public extension LibSession.Cache {
    func observe(_ key: LibSession.ObservableKey) -> AsyncStream<Any?> {
        let id: UUID = UUID()
        
        return AsyncStream { [weak observerStore] continuation in
            Task {
                await observerStore?.addContinuation(continuation, for: key, id: id)
            }
            continuation.onTermination = { [weak observerStore] _ in
                Task { await observerStore?.removeContinuation(for: key, id: id) }
            }
        }
    }
}

public extension LibSessionCacheType {
    private func observe<T>(_ key: LibSession.ObservableKey, defaultValue: T) -> AsyncMapSequence<AsyncStream<Any?>, T> {
        return observe(key).map { newValue in
            let newTypedValue: T? = (newValue as? T)
            
            if newValue != nil && newTypedValue == nil {
                Log.warn(.libSession, "Failed to cast new value for key \(key) to \(T.self), using default: \(defaultValue)")
            }
            
            return (newTypedValue ?? defaultValue)
        }
    }
    
    func observe(_ key: Setting.BoolKey) -> AsyncMapSequence<AsyncStream<Any?>, Bool> {
        return observe(.setting(key), defaultValue: false)
    }
    
    func observe<T: LibSessionConvertibleEnum>(_ key: Setting.EnumKey, defaultValue: T) -> AsyncMapSequence<AsyncStream<Any?>, T> {
        return observe(.setting(key), defaultValue: defaultValue)
    }
}

// MARK: - State Access

public extension LibSession.Cache {
    func has(_ key: Setting.BoolKey) -> Bool {
        /// If a `bool` value doesn't exist then we return a negative value
        switch key {
            case .checkForCommunityMessageRequests:
                guard case .userProfile(let conf) = config(for: .userProfile, sessionId: userSessionId) else {
                    return false
                }
                
                return (user_profile_get_blinded_msgreqs(conf) >= 0)
            
            default:
                guard case .local(let conf) = config(for: .local, sessionId: userSessionId) else {
                    return false
                }
                
                return (local_get_setting(conf, key.rawValue) >= 0)
        }
    }
    
    func has(_ key: Setting.EnumKey) -> Bool {
        guard case .local(let conf) = config(for: .local, sessionId: userSessionId) else {
            return false
        }
        
        switch key {
            case .preferencesNotificationPreviewType:
                return (local_get_notification_content(conf) != Preferences.NotificationPreviewType.defaultLibSessionValue)
            
            case .defaultNotificationSound:
                return (local_get_notification_sound(conf) != Preferences.Sound.defaultLibSessionValue)
            
            case .theme: return (local_get_theme(conf) != Theme.defaultLibSessionValue)
            case .themePrimaryColor:
                return (local_get_theme_primary_color(conf) != Theme.PrimaryColor.defaultLibSessionValue)
            
            default:
                Log.critical(.libSession, "Failed to check existence of unknown '\(key)' setting due to missing libSesison function")
                return false
        }
    }
    
    func get(_ key: Setting.BoolKey) -> Bool {
        switch key {
            case .checkForCommunityMessageRequests:
                guard case .userProfile(let conf) = config(for: .userProfile, sessionId: userSessionId) else {
                    return false
                }
                
                return (user_profile_get_blinded_msgreqs(conf) > 0)
                
            default:
                guard case .local(let conf) = config(for: .local, sessionId: userSessionId) else {
                    return false
                }
                
                return (local_get_setting(conf, key.rawValue) > 0)
        }
    }
    
    func get<T: LibSessionConvertibleEnum>(_ key: Setting.EnumKey) -> T? {
        guard case .local(let conf) = config(for: .local, sessionId: userSessionId) else {
            return nil
        }
        
        let retriever: (UnsafePointer<config_object>) -> Any? = {
            switch key {
                case .preferencesNotificationPreviewType: return local_get_notification_content
                case .defaultNotificationSound: return local_get_notification_sound
                case .theme: return local_get_theme
                case .themePrimaryColor: return local_get_theme_primary_color
                default: return { _ in nil }
            }
        }()
        
        switch retriever(conf) {
            case let libSessionValue as T.LibSessionType: return T(libSessionValue)
            case .some:
                Log.critical(.libSession, "Failed to get \(key) because we couldn't cast to the C type")
                return nil
                
            case .none:
                Log.critical(.libSession, "Failed to get unknown '\(key)' setting due to missing libSesison function")
                return nil
        }
    }
    
    func set(_ key: Setting.BoolKey, _ value: Bool?) async {
        let valueAsInt: Int32 = {
            switch value {
                case .none: return -1
                case .some(false): return 0
                case .some(true): return 1
            }
        }()
        
        switch key {
            case .checkForCommunityMessageRequests:
                guard case .userProfile(let conf) = config(for: .userProfile, sessionId: userSessionId) else {
                    return Log.critical(.libSession, "Failed to set \(key) because there is no UserProfile config")
                }
                
                user_profile_set_blinded_msgreqs(conf, valueAsInt)
                
            default:
                guard case .local(let conf) = config(for: .local, sessionId: userSessionId) else {
                    return Log.critical(.libSession, "Failed to set \(key) because there is no UserProfile config")
                }
                
                local_set_setting(conf, key.rawValue, valueAsInt)
        }
        
        /// Add a pending observation to notify any observers of the change once it's committed
        await addPendingChange(key: key, value: value)
    }
    
    func set<T: LibSessionConvertibleEnum>(_ key: Setting.EnumKey, _ value: T?) async {
        guard case .local(let conf) = config(for: .local, sessionId: userSessionId) else {
            return Log.critical(.libSession, "Failed to set \(key) because there is no UserProfile config")
        }
        
        let libSessionValue: T.LibSessionType = (value?.libSessionValue ?? T.defaultLibSessionValue)
        
        switch key {
            case .defaultNotificationSound:
                guard let value: CLIENT_NOTIFY_SOUND = libSessionValue as? CLIENT_NOTIFY_SOUND else {
                    return Log.critical(.libSession, "Failed to set \(key) because we couldn't cast to the C type")
                }
                
                local_set_notification_sound(conf, value)
                
            case .preferencesNotificationPreviewType:
                guard let value: CLIENT_NOTIFY_CONTENT = libSessionValue as? CLIENT_NOTIFY_CONTENT else {
                    return Log.critical(.libSession, "Failed to set \(key) because we couldn't cast to the C type")
                }
                
                local_set_notification_content(conf, value)
                
            case .theme:
                guard let value: CLIENT_THEME = libSessionValue as? CLIENT_THEME else {
                    return Log.critical(.libSession, "Failed to set \(key) because we couldn't cast to the C type")
                }
                
                local_set_theme(conf, value)
                
            case .themePrimaryColor:
                guard let value: CLIENT_THEME_PRIMARY_COLOR = libSessionValue as? CLIENT_THEME_PRIMARY_COLOR else {
                    return Log.critical(.libSession, "Failed to set \(key) because we couldn't cast to the C type")
                }
                
                local_set_theme_primary_color(conf, value)
                
            default: Log.critical(.libSession, "Failed to set unknown \(key) due to missing libSesison function")
        }
        
        /// Add a pending observation to notify any observers of the change once it's committed
        await addPendingChange(key: key, value: value)
    }
}

// MARK: - LibSessionConvertibleEnum

public protocol LibSessionConvertibleEnum {
    associatedtype LibSessionType
    
    static var defaultLibSessionValue: LibSessionType { get }
    var libSessionValue: LibSessionType { get }
    
    init(_ libSessionValue: LibSessionType)
}

extension Preferences.NotificationPreviewType: LibSessionConvertibleEnum {
    public typealias LibSessionType = CLIENT_NOTIFY_CONTENT
    
    public static var defaultLibSessionValue: LibSessionType { CLIENT_NOTIFY_CONTENT_DEFAULT }
    public var libSessionValue: LibSessionType {
        switch self {
            case .nameAndPreview: return CLIENT_NOTIFY_CONTENT_NAME_AND_PREVIEW
            case .nameNoPreview: return CLIENT_NOTIFY_CONTENT_NAME_NO_PREVIEW
            case .noNameNoPreview: return CLIENT_NOTIFY_CONTENT_NO_NAME_NO_PREVIEW
        }
    }
    
    public init(_ libSessionValue: LibSessionType) {
        switch libSessionValue {
            case CLIENT_NOTIFY_CONTENT_NAME_AND_PREVIEW: self = .nameAndPreview
            case CLIENT_NOTIFY_CONTENT_NAME_NO_PREVIEW: self = .nameNoPreview
            case CLIENT_NOTIFY_CONTENT_NO_NAME_NO_PREVIEW: self = .noNameNoPreview
            default: self = Preferences.NotificationPreviewType.defaultPreviewType
        }
    }
}

extension Preferences.Sound: LibSessionConvertibleEnum {
    public typealias LibSessionType = CLIENT_NOTIFY_SOUND
    
    public static var defaultLibSessionValue: LibSessionType { CLIENT_NOTIFY_SOUND_DEFAULT }
    public var libSessionValue: LibSessionType {
        switch self {
            case .none: return CLIENT_NOTIFY_SOUND_NONE
            case .aurora: return CLIENT_NOTIFY_SOUND_AURORA
            case .bamboo: return CLIENT_NOTIFY_SOUND_BAMBOO
            case .chord: return CLIENT_NOTIFY_SOUND_CHORD
            case .circles: return CLIENT_NOTIFY_SOUND_CIRCLES
            case .complete: return CLIENT_NOTIFY_SOUND_COMPLETE
            case .hello: return CLIENT_NOTIFY_SOUND_HELLO
            case .input: return CLIENT_NOTIFY_SOUND_INPUT
            case .keys: return CLIENT_NOTIFY_SOUND_KEYS
            case .note: return CLIENT_NOTIFY_SOUND_NOTE
            case .popcorn: return CLIENT_NOTIFY_SOUND_POPCORN
            case .pulse: return CLIENT_NOTIFY_SOUND_PULSE
            case .synth: return CLIENT_NOTIFY_SOUND_SYNTH
            
            /// Use the default for all other values
            default: return Preferences.Sound.defaultLibSessionValue
        }
    }
    
    public init(_ libSessionValue: LibSessionType) {
        switch libSessionValue {
            case CLIENT_NOTIFY_SOUND_NONE: self = .none
            case CLIENT_NOTIFY_SOUND_AURORA: self = .aurora
            case CLIENT_NOTIFY_SOUND_BAMBOO: self = .bamboo
            case CLIENT_NOTIFY_SOUND_CHORD: self = .chord
            case CLIENT_NOTIFY_SOUND_CIRCLES: self = .circles
            case CLIENT_NOTIFY_SOUND_COMPLETE: self = .complete
            case CLIENT_NOTIFY_SOUND_HELLO: self = .hello
            case CLIENT_NOTIFY_SOUND_INPUT: self = .input
            case CLIENT_NOTIFY_SOUND_KEYS: self = .keys
            case CLIENT_NOTIFY_SOUND_NOTE: self = .note
            case CLIENT_NOTIFY_SOUND_POPCORN: self = .popcorn
            case CLIENT_NOTIFY_SOUND_PULSE: self = .pulse
            case CLIENT_NOTIFY_SOUND_SYNTH: self = .synth
            default: self = Preferences.Sound.default
        }
    }
}

extension Theme: LibSessionConvertibleEnum {
    public typealias LibSessionType = CLIENT_THEME
    
    public static var defaultLibSessionValue: LibSessionType { CLIENT_THEME_DEFAULT }
    public var libSessionValue: LibSessionType {
        switch self {
            case .classicDark: return CLIENT_THEME_CLASSIC_DARK
            case .classicLight: return CLIENT_THEME_CLASSIC_LIGHT
            case .oceanDark: return CLIENT_THEME_OCEAN_DARK
            case .oceanLight: return CLIENT_THEME_OCEAN_LIGHT
        }
    }
    
    public init(_ libSessionValue: LibSessionType) {
        switch libSessionValue {
            case CLIENT_THEME_CLASSIC_DARK: self = .classicDark
            case CLIENT_THEME_CLASSIC_LIGHT: self = .classicLight
            case CLIENT_THEME_OCEAN_DARK: self = .oceanDark
            case CLIENT_THEME_OCEAN_LIGHT: self = .oceanLight
            default: self = Theme.defaultTheme
        }
    }
}

extension Theme.PrimaryColor: LibSessionConvertibleEnum {
    public typealias LibSessionType = CLIENT_THEME_PRIMARY_COLOR
    
    public static var defaultLibSessionValue: LibSessionType { CLIENT_THEME_PRIMARY_COLOR_DEFAULT }
    public var libSessionValue: LibSessionType {
        switch self {
            case .green: return CLIENT_THEME_PRIMARY_COLOR_GREEN
            case .blue: return CLIENT_THEME_PRIMARY_COLOR_BLUE
            case .yellow: return CLIENT_THEME_PRIMARY_COLOR_YELLOW
            case .pink: return CLIENT_THEME_PRIMARY_COLOR_PINK
            case .purple: return CLIENT_THEME_PRIMARY_COLOR_PURPLE
            case .orange: return CLIENT_THEME_PRIMARY_COLOR_ORANGE
            case .red: return CLIENT_THEME_PRIMARY_COLOR_RED
        }
    }
    
    public init(_ libSessionValue: LibSessionType) {
        switch libSessionValue {
            case CLIENT_THEME_PRIMARY_COLOR_GREEN: self = .green
            case CLIENT_THEME_PRIMARY_COLOR_BLUE: self = .blue
            case CLIENT_THEME_PRIMARY_COLOR_YELLOW: self = .yellow
            case CLIENT_THEME_PRIMARY_COLOR_PINK: self = .pink
            case CLIENT_THEME_PRIMARY_COLOR_PURPLE: self = .purple
            case CLIENT_THEME_PRIMARY_COLOR_ORANGE: self = .orange
            case CLIENT_THEME_PRIMARY_COLOR_RED: self = .red
            default: self = Theme.PrimaryColor.defaultPrimaryColor
        }
    }
}
