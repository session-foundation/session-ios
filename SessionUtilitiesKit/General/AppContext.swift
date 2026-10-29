// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import UIKit

// MARK: - Log.Category

public extension Log.Category {
    static let appContext: Log.Category = .create("appContext", defaultLevel: .info)
}

// MARK: - Singleton

public extension Singleton {
    static let appContext: SingletonConfig<AppContext> = Dependencies.create(
        identifier: "appContext",
        createInstance: { _, _ in NoopAppContext() }
    )
}

// MARK: - AppContext

public protocol AppContext: AnyObject {
    var isValid: Bool { get }
    var appLaunchTime: Date { get }
    var isMainApp: Bool { get }
    var shouldDeferNetworkInitialisation: Bool { get }
    @MainActor var isMainAppAndForeground: Bool { get }
    var isShareExtension: Bool { get }
    var reportedApplicationState: UIApplication.State { get }
    var mainWindow: UIWindow? { get }
    @MainActor var frontMostViewController: UIViewController? { get }
    
    @MainActor func setMainWindow(_ mainWindow: UIWindow)
    func ensureSleepBlocking(_ shouldBeBlocking: Bool, blockingObjects: [Any])
    
    /// The docs for `UIApplication.shared.beginBackgroundTask` specify - the `expirationHandler` is called shortly
    /// before the app’s remaining background time reaches 0. Use this handler to clean up and mark the end of the background task.
    /// Failure to end the task explicitly will result in the termination of the app. The system calls the handler synchronously on the main
    /// thread, blocking the app’s suspension momentarily.
    func beginBackgroundTask(expirationHandler: @escaping () -> ()) -> UIBackgroundTaskIdentifier
    func endBackgroundTask(_ backgroundTaskIdentifier: UIBackgroundTaskIdentifier)
    func openUrl(_ url: URL)
}

// MARK: - Defaults

public extension AppContext {
    var isValid: Bool { true }
    var isMainApp: Bool { false }
    var shouldDeferNetworkInitialisation: Bool { false }
    var isMainAppAndForeground: Bool { false }
    var isShareExtension: Bool { false }
    var mainWindow: UIWindow? { nil }
    var frontMostViewController: UIViewController? { nil }
    
    // Note: CallKit will make the app state as .inactive
    var isInBackground: Bool { reportedApplicationState == .background }
    var isNotInForeground: Bool { reportedApplicationState != .active }
    var isAppForegroundAndActive: Bool { reportedApplicationState == .active }
    
    // MARK: - Functions
    
    func setMainWindow(_ mainWindow: UIWindow) {}
    func ensureSleepBlocking(_ shouldBeBlocking: Bool, blockingObjects: [Any]) {}
    func beginBackgroundTask(expirationHandler: @escaping () -> ()) -> UIBackgroundTaskIdentifier { return .invalid }
    func endBackgroundTask(_ backgroundTaskIdentifier: UIBackgroundTaskIdentifier) {}
    func openUrl(_ url: URL) {}
}

private final class NoopAppContext: AppContext, NoopDependency {
    let mainWindow: UIWindow? = nil
    let frontMostViewController: UIViewController? = nil
    
    var isValid: Bool { false }
    var appLaunchTime: Date { Date(timeIntervalSince1970: 0) }
    var isMainApp: Bool { false }
    var isMainAppAndForeground: Bool { false }
    var isShareExtension: Bool { false }
    var reportedApplicationState: UIApplication.State { .inactive }
    
    // Override the extension functions
    var isInBackground: Bool { false }
    var isAppForegroundAndActive: Bool { false }
    
    func setMainWindow(_ mainWindow: UIWindow) {}
    func ensureSleepBlocking(_ shouldBeBlocking: Bool, blockingObjects: [Any]) {}
    func beginBackgroundTask(expirationHandler: @escaping () -> ()) -> UIBackgroundTaskIdentifier { return .invalid }
    func endBackgroundTask(_ backgroundTaskIdentifier: UIBackgroundTaskIdentifier) {}
    func openUrl(_ url: URL) {}
}

// MARK: - MainAppLease

/// Whether the main app is in the foreground, shared with the extensions via the app group
///
/// It expires unless the main app keeps renewing it, because a process which crashes or is killed while in the foreground never runs
/// the code which would clear it - so the extensions resume handling pushes within `duration` rather than when the app next opens
public enum MainAppLease {
    /// How far ahead of now each renewal sets the lease
    public static let duration: TimeInterval = 90
    
    /// How often the main app renews the lease while active, a few renewals fit into `duration` so a late timer doesn't lapse it
    public static let renewalInterval: TimeInterval = 30
    
    /// A lease further ahead than `duration` plus this can't have come from a renewal, so must be the result of the clock
    /// moving backwards after it was written
    public static let clockSkewAllowance: TimeInterval = 30
    
    public enum State: Equatable, CustomStringConvertible {
        case none
        case active(until: Date, now: Date)
        case expired(at: Date, now: Date)
        case invalid(until: Date, now: Date)
        
        public var isActive: Bool {
            switch self {
                case .active: return true
                case .none, .expired, .invalid: return false
            }
        }
        
        // stringlint:ignore_contents
        public var description: String {
            switch self {
                case .none: return "no lease"
                case .active(let until, let now): return "lease valid until \(MainAppLease.format(until, relativeTo: now))"
                case .expired(let at, let now): return "lease expired at \(MainAppLease.format(at, relativeTo: now))"
                case .invalid(let until, let now): return "lease ignored, too far ahead: \(MainAppLease.format(until, relativeTo: now))"
            }
        }
    }
    
    public static func state(until: Date?, now: Date) -> State {
        guard let until: Date = until else { return .none }
        guard until <= now.addingTimeInterval(duration + clockSkewAllowance) else {
            return .invalid(until: until, now: now)
        }
        
        return (now < until ? .active(until: until, now: now) : .expired(at: until, now: now))
    }
    
    // stringlint:ignore_contents
    private static let timeFormatter: DateFormatter = {
        let formatter: DateFormatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
    
    // stringlint:ignore_contents
    private static func format(_ date: Date, relativeTo now: Date) -> String {
        let seconds: Int = Int(date.timeIntervalSince(now).rounded())
        
        return "\(timeFormatter.string(from: date)) (\(seconds >= 0 ? "+" : "")\(seconds)s)"
    }
}

public extension Dependencies {
    var mainAppLease: MainAppLease.State {
        MainAppLease.state(until: self[defaults: .appGroup, key: .mainAppActiveUntil], now: dateNow)
    }
    
    /// Whether the main app currently holds the lease, use this rather than the app context's state from code which can run in an
    /// extension, or which shouldn't need to hop to the main thread
    var isMainAppActive: Bool { mainAppLease.isActive }
    
    /// Should only be called from the main app
    @discardableResult func renewMainAppLease() -> Date {
        let until: Date = dateNow.addingTimeInterval(MainAppLease.duration)
        self[defaults: .appGroup, key: .mainAppActiveUntil] = until
        
        return until
    }
    
    /// Should only be called from the main app, this leaves an expired lease (rather than removing it) so the extensions can log when
    /// the main app stopped being active
    func endMainAppLease() {
        self[defaults: .appGroup, key: .mainAppActiveUntil] = dateNow
    }
}
