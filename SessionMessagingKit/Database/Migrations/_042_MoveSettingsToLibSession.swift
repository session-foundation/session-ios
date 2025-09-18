// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUIKit
import SessionUtilitiesKit

/// This migration extracts an old settings from the database and saves them into libSession
enum _042_MoveSettingsToLibSession: Migration {
    static let identifier: String = "messagingKit.MoveSettingsToLibSession"
    static let minExpectedRunDuration: TimeInterval = 0.1
    static let createdTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: ObservingDatabase, using dependencies: Dependencies) throws {
        guard
            MigrationHelper.userExists(db),
            let userEd25519SecretKey: Data = MigrationHelper.fetchIdentityValue(db, key: "ed25519SecretKey")
        else { return MigrationExecution.updateProgress(1) }
        
        let boolSettings: [Setting.BoolKey] = [
            .areReadReceiptsEnabled,
            .typingIndicatorsEnabled,
            .isScreenLockEnabled,
            .areLinkPreviewsEnabled,
            .isGiphyEnabled,
            .areCallsEnabled,
            .trimOpenGroupMessagesOlderThanSixMonths,
            .hasHiddenMessageRequests,
            .playNotificationSoundInForeground,
            .hasViewedSeed,
            .hideRecoveryPasswordPermanently,
            .hasSavedThread,
            .hasSentAMessage,
            .shouldAutoPlayConsecutiveAudioMessages,
            .developerModeEnabled,
            .lastSeenHasLocalNetworkPermission,
            .themeMatchSystemDayNightCycle
        ]
        let settings: [String: Data] = try Row
            .fetchAll(db, sql: "SELECT key, value FROM keyValueStore")
            .reduce(into: [:]) { result, next in
                guard
                    let key: String = next["key"] as? String,
                    let data: Data = next["value"] as? Data
                else { return }
                
                result[key] = data
            }
        let userSessionId: SessionId = MigrationHelper.userSessionId(db)
        let cache: LibSession.Cache = LibSession.Cache(userSessionId: userSessionId, using: dependencies)
        cache.setConfig(
            for: .local,
            sessionId: userSessionId,
            to: try cache.loadState(
                for: .local,
                sessionId: userSessionId,
                userEd25519SecretKey: Array(userEd25519SecretKey),
                groupEd25519SecretKey: nil,
                cachedData: MigrationHelper.configDump(db, for: ConfigDump.Variant.local.rawValue)
            )
        )
        
        var taskError: Error?
        var mutation: LibSession.Mutation?
        var keysToDrop: [String] = [
            "isReadyForAppExtensions"   /// Removed as we can infer this based on `UserMetadata` existing now
        ]
        let semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                mutation = try cache.perform(for: .local) {
                    /// Move bool settings across
                    for key in boolSettings {
                        guard let data: Data = settings[key.rawValue] else { continue }
                        
                        let boolValue: Bool = data.withUnsafeBytes { $0.loadUnaligned(as: Bool.self) }
                        cache.set(key, boolValue)
                        keysToDrop.append(key.rawValue)
                    }
                    
                    /// Move enum settings across explicitly (since they need to be set using their enum values)
                    if
                        let data: Data = settings[Setting.EnumKey.preferencesNotificationPreviewType.rawValue],
                        let enumValue: Preferences.NotificationPreviewType = Preferences.NotificationPreviewType(
                            rawValue: data.withUnsafeBytes { $0.loadUnaligned(as: Int.self) }
                        )
                    {
                        cache.set(.preferencesNotificationPreviewType, enumValue)
                        keysToDrop.append(Setting.EnumKey.preferencesNotificationPreviewType.rawValue)
                    }
                    
                    if
                        let data: Data = settings[Setting.EnumKey.defaultNotificationSound.rawValue],
                        let enumValue: Preferences.Sound = Preferences.Sound(
                            rawValue: data.withUnsafeBytes { $0.loadUnaligned(as: Int.self) }
                        )
                    {
                        cache.set(.defaultNotificationSound, enumValue)
                        keysToDrop.append(Setting.EnumKey.defaultNotificationSound.rawValue)
                    }
                    
                    /// Convert the `theme` value from a `String` to an `Int`
                    if
                        let data: Data = settings[Setting.EnumKey.theme.rawValue],
                        let stringValue: String = String(data: data, encoding: .utf8),
                        let enumValue: Theme = Theme(legacyStringKey: stringValue)
                    {
                        cache.set(.theme, enumValue)
                        keysToDrop.append(Setting.EnumKey.theme.rawValue)
                    }
                    
                    /// Convert the `themePrimaryColor` value from a `String` to an `Int`
                    if
                        let data: Data = settings[Setting.EnumKey.themePrimaryColor.rawValue],
                        let stringValue: String = String(data: data, encoding: .utf8),
                        let enumValue: Theme.PrimaryColor = Theme.PrimaryColor(legacyStringKey: stringValue)
                    {
                        cache.set(.themePrimaryColor, enumValue)
                        keysToDrop.append(Setting.EnumKey.themePrimaryColor.rawValue)
                    }
                }
            }
            catch { taskError = error }
            
            semaphore.signal()
        }
        semaphore.wait()
        
        /// If an error occurred then throw it
        if let error: Error = taskError {
            throw error
        }
        
        /// Save the updated config dump
        try mutation?.upsert(db)
        
        /// Delete the old settings (since they should no longer be accessed via the database)
        try db.execute(sql: """
            DELETE FROM keyValueStore
            WHERE key IN (\(keysToDrop.map { "'\($0)'" }.joined(separator: ", ")))
        """)
        
        MigrationExecution.updateProgress(1)
    }
}

// MARK: - Converted types

private extension Theme {
    init?(legacyStringKey: String) {
        switch legacyStringKey {
            case "classic_dark": self = .classicDark
            case "classic_light": self = .classicLight
            case "ocean_dark": self = .oceanDark
            case "ocean_light": self = .oceanLight
            default: return nil
        }
    }
}

private extension Theme.PrimaryColor {
    init?(legacyStringKey: String) {
        switch legacyStringKey {
            case "green": self = .green
            case "blue": self = .blue
            case "yellow": self = .yellow
            case "pink": self = .pink
            case "purple": self = .purple
            case "orange": self = .orange
            case "red": self = .red
            default: return nil
        }
    }
}
