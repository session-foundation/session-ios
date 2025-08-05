// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionUIKit
import SessionUtilitiesKit

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
                return (local_get_ios_notification_sound(conf) != Preferences.Sound.defaultLibSessionValue)
            
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
                case .defaultNotificationSound: return local_get_ios_notification_sound
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
    
    func set(_ key: Setting.BoolKey, _ value: Bool?) {
        let valueAsInt: Int32 = {
            switch value {
                case .none: return -1
                case .some(false): return 0
                case .some(true): return 1
            }
        }()
        
        var currentValue: Int32?
        
        switch key {
            case .checkForCommunityMessageRequests:
                guard case .userProfile(let conf) = config(for: .userProfile, sessionId: userSessionId) else {
                    return Log.critical(.libSession, "Failed to set \(key) because there is no Local config")
                }
                
                currentValue = user_profile_get_blinded_msgreqs(conf)
                user_profile_set_blinded_msgreqs(conf, valueAsInt)
                
            default:
                guard case .local(let conf) = config(for: .local, sessionId: userSessionId) else {
                    return Log.critical(.libSession, "Failed to set \(key) because there is no Local config")
                }
                
                currentValue = local_get_setting(conf, key.rawValue)
                local_set_setting(conf, key.rawValue, valueAsInt)
        }
        
        /// Add an event to notify any observers of the change once it's committed (only if the value was changed)
        if valueAsInt != currentValue {
            addEvent(key: key, value: value)
        }
    }
    
    func set<T: LibSessionConvertibleEnum>(_ key: Setting.EnumKey, _ value: T?) {
        guard case .local(let conf) = config(for: .local, sessionId: userSessionId) else {
            return Log.critical(.libSession, "Failed to set \(key) because there is no Local config")
        }
        
        let libSessionValue: T.LibSessionType = (value?.libSessionValue ?? T.defaultLibSessionValue)
        let currentLibSessionValue: T? = get(key)
        
        switch key {
            case .defaultNotificationSound:
                guard let value: Int64 = libSessionValue as? Int64 else {
                    return Log.critical(.libSession, "Failed to set \(key) because we couldn't cast to the C type")
                }
                
                local_set_ios_notification_sound(conf, value)
                
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
        
        /// Add an event to notify any observers of the change once it's committed (only if the value was changed)
        if value != currentLibSessionValue {
            addEvent(key: key, value: value)
        }
    }
}

// MARK: - LibSessionConvertibleEnum

public protocol LibSessionConvertibleEnum: Hashable {
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
    public typealias LibSessionType = Int64
    
    public static var defaultLibSessionValue: LibSessionType { 0 }
    public var libSessionValue: LibSessionType { Int64(rawValue) }
    
    public init(_ libSessionValue: LibSessionType) {
        guard
            libSessionValue != Preferences.Sound.defaultLibSessionValue,
            let targetSound: Preferences.Sound = Preferences.Sound(rawValue: Int(libSessionValue))
        else {
            self = Preferences.Sound.defaultNotificationSound
            return
        }
        
        self = targetSound
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
