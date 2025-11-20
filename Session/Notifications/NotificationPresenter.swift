// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUIKit
import SessionMessagingKit
import SignalUtilitiesKit
import SessionUtilitiesKit

// MARK: - NotificationPresenter

public class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate, NotificationsManagerType {
    private static let audioNotificationsThrottleCount = 2
    private static let audioNotificationsThrottleInterval: TimeInterval = 5
    
    public let dependencies: Dependencies
    private let notificationCenter: UNUserNotificationCenter = UNUserNotificationCenter.current()
    @ThreadSafeObject private var notifications: [String: UNNotificationRequest] = [:]
    @ThreadSafeObject private var mostRecentNotifications: TruncatedList<UInt64> = TruncatedList<UInt64>(maxLength: NotificationPresenter.audioNotificationsThrottleCount)
    @ThreadSafeObject private var settingsStorage: [String: Preferences.NotificationSettings] = [:]
    @ThreadSafe private var notificationSound: Preferences.Sound = .defaultNotificationSound
    @ThreadSafe private var notificationPreviewType: Preferences.NotificationPreviewType = .defaultPreviewType
    
    // MARK: - Initialization
    
    required public init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        
        super.init()
        
        /// Populate the notification settings from `libSession` and the database
        Task.detached(priority: .high) { [weak self] in
            do { try await dependencies.waitUntilInitialised(cache: .libSession) }
            catch {
                Log.error("[NotificationPresenter] Failed to wait until libSession initialised: \(error)")
                return
            }
            
            typealias GlobalSettings = (
                sound: Preferences.Sound,
                previewType: Preferences.NotificationPreviewType
            )
            struct ThreadSettings: Codable, FetchableRecord {
                let id: String
                let variant: SessionThread.Variant
                let mutedUntilTimestamp: TimeInterval?
                let onlyNotifyForMentions: Bool
            }
            
            let prefs: GlobalSettings = dependencies.mutate(cache: .libSession) {
                (
                    $0.get(.defaultNotificationSound).defaulting(to: .defaultNotificationSound),
                    $0.get(.preferencesNotificationPreviewType).defaulting(to: .defaultPreviewType)
                )
            }
            let allSettings: [ThreadSettings] = (try? await dependencies[singleton: .storage]
                .readAsync { db in
                    try SessionThread
                        .select(.id, .variant, .mutedUntilTimestamp, .onlyNotifyForMentions)
                        .asRequest(of: ThreadSettings.self)
                        .fetchAll(db)
                })
                .defaulting(to: [])
            let notificationSettings: [String: Preferences.NotificationSettings] = allSettings
                .reduce(into: [:]) { result, setting in
                    result[setting.id] = Preferences.NotificationSettings(
                        previewType: prefs.previewType,
                        sound: prefs.sound,
                        mentionsOnly: setting.onlyNotifyForMentions,
                        mutedUntil: setting.mutedUntilTimestamp
                    )
                }
            
            /// Store the settings in memory
            self?.notificationSound = prefs.sound
            self?.notificationPreviewType = prefs.previewType
            self?._settingsStorage.set(to: notificationSettings)
            
            /// Replicate the settings for the PN extension if needed
            do {
                try dependencies[singleton: .extensionHelper].replicate(
                    settings: notificationSettings,
                    replaceExisting: false
                )
            }
            catch {
                Log.error("[NotificationPresenter] Failed to replicate settings due to error: \(error)")
            }
        }
    }
    
    // MARK: - Registration
    
    public func setDelegate(_ delegate: (any UNUserNotificationCenterDelegate)?) {
        notificationCenter.delegate = delegate
    }
    
    public func registerSystemNotificationSettings() -> AnyPublisher<Void, Never> {
        return Deferred { [notificationCenter] in
            Future { resolver in
                notificationCenter.requestAuthorization(options: [.badge, .sound, .alert]) { (granted, error) in
                    notificationCenter.setNotificationCategories(UserNotificationConfig.allNotificationCategories)
                    
                    switch (granted, error) {
                        case (true, _): break
                        case (false, .some(let error)): Log.error("[NotificationPresenter] Register settings failed with error: \(error)")
                        case (false, .none): Log.error("[NotificationPresenter] Register settings failed without error.")
                    }
                    
                    // Note that the promise is fulfilled regardless of if notification permssions were
                    // granted. This promise only indicates that the user has responded, so we can
                    // proceed with requesting push tokens and complete registration.
                    resolver(Result.success(()))
                }
            }
        }.eraseToAnyPublisher()
    }
    
    // MARK: - Unique Logic
    
    public func settings(threadId: String? = nil, threadVariant: SessionThread.Variant) -> Preferences.NotificationSettings {
        return settingsStorage[threadId].defaulting(
            to: Preferences.NotificationSettings(
                previewType: notificationPreviewType,
                sound: notificationSound,
                mentionsOnly: false,
                mutedUntil: nil
            )
        )
    }
    
    public func updateSettings(
        threadId: String,
        threadVariant: SessionThread.Variant,
        mentionsOnly: Bool,
        mutedUntil: TimeInterval?
    ) {
        /// Update the in-memory cache first
        var oldMentionsOnly: Bool?
        var oldMutedUntil: TimeInterval?
        
        _settingsStorage.performUpdate { settings in
            oldMentionsOnly = settings[threadId]?.mentionsOnly
            oldMutedUntil = settings[threadId]?.mutedUntil
            
            return settings.setting(
                threadId,
                Preferences.NotificationSettings(
                    previewType: notificationPreviewType,
                    sound: notificationSound,
                    mentionsOnly: mentionsOnly,
                    mutedUntil: mutedUntil
                )
            )
        }
        
        /// Update the database with the changes
        let changes: [ConfigColumnAssignment] = [
            (mentionsOnly == oldMentionsOnly ? nil :
                SessionThread.Columns.onlyNotifyForMentions.set(to: mentionsOnly)
            ),
            (mutedUntil == oldMutedUntil ? nil :
                SessionThread.Columns.mutedUntilTimestamp.set(to: mutedUntil)
            )
        ].compactMap { $0 }
        
        if !changes.isEmpty {
            dependencies[singleton: .storage].writeAsync { db in
                try SessionThread
                    .filter(id: threadId)
                    .updateAll(db, changes)
                
                if mentionsOnly == oldMentionsOnly {
                    db.addConversationEvent(id: threadId, type: .updated(.onlyNotifyForMentions(mentionsOnly)))
                }
                
                if mutedUntil != oldMutedUntil {
                    db.addConversationEvent(id: threadId, type: .updated(.mutedUntilTimestamp(mutedUntil)))
                }
            }
        }
        
        /// Replicate the settings across to the PN extension
        do {
            try dependencies[singleton: .extensionHelper].replicate(
                settings: settingsStorage,
                replaceExisting: true
            )
        }
        catch {
            Log.error("[NotificationPresenter] Failed to replicate settings due to error: \(error)")
        }
    }
    
    public func notificationUserInfo(threadId: String, threadVariant: SessionThread.Variant) -> [String: Any] {
        return [
            NotificationUserInfoKey.threadId: threadId,
            NotificationUserInfoKey.threadVariantRaw: threadVariant.rawValue
        ]
    }
    
    public func notificationShouldPlaySound(applicationState: UIApplication.State) -> Bool {
        guard applicationState == .active else { return true }
        guard dependencies.mutate(cache: .libSession, { $0.get(.playNotificationSoundInForeground) }) else {
            return false
        }

        let nowMs: UInt64 = UInt64(floor(Date().timeIntervalSince1970 * 1000))
        let recentThreshold = nowMs - UInt64(NotificationPresenter.audioNotificationsThrottleInterval * 1000)

        let recentNotifications = mostRecentNotifications.filter { $0 > recentThreshold }

        guard recentNotifications.count < NotificationPresenter.audioNotificationsThrottleCount else { return false }

        _mostRecentNotifications.performUpdate { $0.appending(nowMs) }
        return true
    }
    
    // MARK: - Presentation
    
    public func notifyForFailedSend(
        threadId: String,
        threadVariant: SessionThread.Variant,
        applicationState: UIApplication.State
    ) {
        let notificationSettings: Preferences.NotificationSettings = settings(threadId: threadId, threadVariant: threadVariant)
        var content: NotificationContent = NotificationContent(
            threadId: threadId,
            threadVariant: threadVariant,
            identifier: threadId,
            category: .errorMessage,
            groupingIdentifier: .threadId(threadId),
            body: "messageErrorDelivery".localized(),
            sound: notificationSettings.sound,
            userInfo: notificationUserInfo(threadId: threadId, threadVariant: threadVariant),
            applicationState: applicationState
        )
        
        /// Add the title if needed
        switch notificationSettings.previewType {
            case .noNameNoPreview: content = content.with(title: Constants.app_name)
            case .nameNoPreview, .nameAndPreview:
                typealias ThreadInfo = (profile: Profile?, openGroupName: String?, openGroupUrlInfo: LibSession.OpenGroupUrlInfo?)
                let threadInfo: ThreadInfo? = dependencies[singleton: .storage].read { db in
                    return (
                        (threadVariant != .contact ? nil :
                            try? Profile.fetchOne(db, id: threadId)
                        ),
                        (threadVariant != .community ? nil :
                            try? OpenGroup
                                .select(.name)
                                .filter(id: threadId)
                                .asRequest(of: String.self)
                                .fetchOne(db)
                        ),
                        (threadVariant != .community ? nil :
                            try? LibSession.OpenGroupUrlInfo.fetchOne(db, id: threadId)
                        )
                    )
                }
                
                content = content.with(
                    title: dependencies.mutate(cache: .libSession) { cache in
                        cache.conversationDisplayName(
                            threadId: threadId,
                            threadVariant: threadVariant,
                            contactProfile: threadInfo?.profile,
                            visibleMessage: nil,    /// This notification is unrelated to the received message
                            openGroupName: threadInfo?.openGroupName,
                            openGroupUrlInfo: threadInfo?.openGroupUrlInfo
                        )
                    }
                )
        }
        
        addNotificationRequest(
            content: content,
            notificationSettings: notificationSettings,
            extensionBaseUnreadCount: nil
        )
    }
    
    // MARK: - Schedule New Session Network Page local notifcation
    
    public func scheduleSessionNetworkPageLocalNotifcation(force: Bool) {
        guard
            force ||
            dependencies[defaults: .standard, key: .isSessionNetworkPageNotificationScheduled] != true
        else { return }
        
        let notificationSettings: Preferences.NotificationSettings = settings(threadVariant: .contact)
        let identifier: String = "sessionNetworkPageLocalNotifcation_\(UUID().uuidString)" // stringlint:disable
        
        // Schedule the notification after 1 hour
        let content: NotificationContent = NotificationContent(
            threadId: nil,
            threadVariant: nil,
            identifier: identifier,
            category: .info,
            title: Constants.app_name,
            body: "sessionNetworkNotificationLive"
                .put(key: "token_name_long", value: Constants.token_name_long)
                .put(key: "network_name", value: Constants.network_name)
                .localized(),
            delay: (force ? 10 : 3600),
            sound: notificationSettings.sound,
            userInfo: [:],
            applicationState: dependencies[singleton: .appContext].reportedApplicationState
        )
        
        addNotificationRequest(
            content: content,
            notificationSettings: notificationSettings,
            extensionBaseUnreadCount: nil
        )
        dependencies[defaults: .standard, key: .isSessionNetworkPageNotificationScheduled] = true
    }
    
    public func addNotificationRequest(
        content: NotificationContent,
        notificationSettings: Preferences.NotificationSettings,
        extensionBaseUnreadCount: Int?
    ) {
        var trigger: UNNotificationTrigger? = content.delay.map { delayInterval in
            UNTimeIntervalNotificationTrigger(
                timeInterval: delayInterval,
                repeats: false
            )
        }
        let shouldPresentNotification: Bool = shouldPresentNotification(
            threadId: content.threadId,
            category: content.category,
            applicationState: content.applicationState,
            using: dependencies
        )
        let mutableContent: UNMutableNotificationContent = content.toMutableContent(
            shouldPlaySound: notificationShouldPlaySound(applicationState: content.applicationState)
        )
        
        switch shouldPresentNotification {
            case true:
                let shouldDelayNotificationForBatching: Bool = (
                    content.threadVariant == .community &&
                    content.identifier == content.threadId
                )

                if shouldDelayNotificationForBatching {
                    /// Only set a trigger for grouped notifications if we don't already have one
                    if trigger == nil {
                        trigger = UNTimeIntervalNotificationTrigger(
                            timeInterval: Notifications.delayForGroupedNotifications,
                            repeats: false
                        )
                    }
                    
                    let numberExistingNotifications: Int? = notifications[content.identifier]?
                        .content
                        .userInfo[NotificationUserInfoKey.threadNotificationCounter]
                        .asType(Int.self)
                    var numberOfNotifications: Int = (numberExistingNotifications ?? 1)
                    
                    if numberExistingNotifications != nil {
                        numberOfNotifications += 1  // Add one for the current notification
                        mutableContent.body = "messageNewYouveGot"
                            .putNumber(numberOfNotifications)
                            .localized()
                    }
                    
                    mutableContent.userInfo[NotificationUserInfoKey.threadNotificationCounter] = numberOfNotifications
                }
                
            case false:
                // Play sound and vibrate, but without a `title` and `body` so the banner won't show
                mutableContent.title = ""
                mutableContent.body = ""
                Log.debug("supressing notification body")
        }
        
        let request = UNNotificationRequest(
            identifier: content.identifier,
            content: mutableContent,
            trigger: trigger
        )

        Log.debug("presenting notification with identifier: \(content.identifier)")
        
        /// If we are replacing a notification then cancel the original one
        if notifications[content.identifier] != nil {
            cancelNotifications(identifiers: [content.identifier])
        }
        
        notificationCenter.add(request)
        _notifications.performUpdate { $0.setting(content.identifier, request) }
    }
    
    // MARK: - Clearing
    
    public func cancelNotifications(identifiers: [String]) {
        _notifications.performUpdate { notifications in
            var updatedNotifications: [String: UNNotificationRequest] = notifications
            identifiers.forEach { updatedNotifications.removeValue(forKey: $0) }
            return updatedNotifications
        }
        notificationCenter.removeDeliveredNotifications(withIdentifiers: identifiers)
        notificationCenter.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
    
    public func clearAllNotifications() {
        notificationCenter.removePendingNotificationRequests(withIdentifiers: notifications.keys.map{$0})
        notificationCenter.removeAllDeliveredNotifications()
    }
}
 
// MARK: - Convenience

private extension NotificationPresenter {
    private func shouldPresentNotification(
        threadId: String?,
        category: NotificationCategory,
        applicationState: UIApplication.State,
        using dependencies: Dependencies
    ) -> Bool {
        guard applicationState == .active else { return true }
        guard category == .incomingMessage || category == .errorMessage else { return true }
        
        /// Check whether the current `frontMostViewController` is a `ConversationVC` for the conversation this notification
        /// would belong to then we don't want to show the notification, so retrieve the `frontMostViewController` (from the main
        /// thread) and check
        let currentOpenConversationThreadId: String? = DispatchQueue.main.sync(execute: {
            (dependencies[singleton: .appContext].frontMostViewController as? ConversationVC)?
                .viewModel
                .state
                .threadId
        })
        
        /// Show notifications for any **other** threads
        return (currentOpenConversationThreadId != threadId)
    }
}

enum NotificationError: Error {
    case assertionError(description: String)
}

extension NotificationError {
    static func failDebug(_ description: String) -> NotificationError {
        Log.error("[NotificationActionHandler] Failed with error: \(description)")
        return NotificationError.assertionError(description: description)
    }
}

// MARK: - TruncatedList

struct TruncatedList<Element>: RangeReplaceableCollection {
    let maxLength: Int
    private var contents: [Element] = []
    
    // MARK: - Initialization
    
    init() {
        self.maxLength = 0
    }

    init(maxLength: Int) {
        self.maxLength = maxLength
    }

    mutating func append(_ newElement: Element) {
        var updatedContents: [Element] = self.contents
        updatedContents.append(newElement)
        self.contents = Array(updatedContents.suffix(maxLength))
    }
    
    mutating func append<S: Sequence>(contentsOf newElements: S) where S.Element == Element {
        var updatedContents: [Element] = self.contents
        updatedContents.append(contentsOf: newElements)
        self.contents = Array(updatedContents.suffix(maxLength))
    }
    
    mutating func insert(_ newElement: Element, at i: Int) {
        var updatedContents: [Element] = self.contents
        updatedContents.insert(newElement, at: i)
        self.contents = updatedContents
    }
    
    mutating func remove(at position: Int) -> Element {
        var updatedContents: [Element] = self.contents
        let result: Element = updatedContents.remove(at: position)
        self.contents = updatedContents
        
        return result
    }
    
    mutating func removeSubrange(_ bounds: Range<Int>) {
        var updatedContents: [Element] = self.contents
        updatedContents.removeSubrange(bounds)
        self.contents = updatedContents
    }
    
    mutating func replaceSubrange<C: Collection>(_ subrange: Range<Int>, with newElements: C) where C.Element == Element {
        var updatedContents: [Element] = self.contents
        updatedContents.replaceSubrange(subrange, with: newElements)
        self.contents = Array(updatedContents.suffix(maxLength))
    }
}

extension TruncatedList {
    func appending(_ other: Element?) -> TruncatedList<Element> {
        guard let other: Element = other else { return self }
        
        var result: TruncatedList<Element> = self
        result.append(other)
        return result
    }
}

extension TruncatedList: Collection {
    typealias Index = Int

    var startIndex: Index {
        return contents.startIndex
    }

    var endIndex: Index {
        return contents.endIndex
    }

    subscript (position: Index) -> Element {
        return contents[position]
    }

    func index(after i: Index) -> Index {
        return contents.index(after: i)
    }
}
