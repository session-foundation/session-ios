// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit
import SignalUtilitiesKit
import SignalCoreKit
import SessionMessagingKit

public class AppEnvironment {

    private static var _shared: AppEnvironment = AppEnvironment()

    public class var shared: AppEnvironment {
        get { return _shared }
        set {
            guard SNUtilitiesKit.isRunningTests else {
                owsFailDebug("Can only switch environments in tests.")
                return
            }

            _shared = newValue
        }
    }

    public var callManager: SessionCallManager
    public var notificationPresenter: NotificationPresenter
    public var pushRegistrationManager: PushRegistrationManager
    public var fileLogger: DDFileLogger

    // Stored properties cannot be marked as `@available`, only classes and functions.
    // Instead, store a private `Any` and wrap it with a public `@available` getter
    private var _userNotificationActionHandler: Any?

    public var userNotificationActionHandler: UserNotificationActionHandler {
        return _userNotificationActionHandler as! UserNotificationActionHandler
    }

    private init() {
        self.callManager = SessionCallManager()
        self.notificationPresenter = NotificationPresenter()
        self.pushRegistrationManager = PushRegistrationManager()
        self._userNotificationActionHandler = UserNotificationActionHandler()
        self.fileLogger = DDFileLogger()
        
        SwiftSingletons.register(self)
    }

    public func setup() {
        // Hang certain singletons on Environment too.
        SessionEnvironment.shared?.callManager.mutate {
            $0 = callManager
        }
        SessionEnvironment.shared?.notificationsManager.mutate {
            $0 = notificationPresenter
        }
        setupLogFiles()
    }
    
    private func setupLogFiles() {
        fileLogger.rollingFrequency = kDayInterval // Refresh everyday
        fileLogger.logFileManager.maximumNumberOfLogFiles = 3 // Save 3 days' log files
        DDLog.add(fileLogger)
        
        // The extensions write their logs to the app shared directory but the main app writes
        // to a local directory (so they can be exported via XCode) - the below code reads any
        // logs from the shared directly and attempts to add them to the main app logs to make
        // debugging user issues in extensions easier
        DispatchQueue.global(qos: .background).async {
            let extensionDirs: [String] = [
                "\(OWSFileSystem.appSharedDataDirectoryPath())/Logs/NotificationExtension",
                "\(OWSFileSystem.appSharedDataDirectoryPath())/Logs/ShareExtension"
            ]
            let extensionLogs: [String] = extensionDirs.flatMap { dir -> [String] in
                guard let files: [String] = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
                
                return files.map { "\(dir)/\($0)" }
            }
            
            extensionLogs.forEach { logFilePath in
                guard let logs: String = try? String(contentsOfFile: logFilePath) else {
                    try? FileManager.default.removeItem(atPath: logFilePath)
                    return
                }
                
                logs.split(separator: "\n").forEach { line in
                    let lineEmoji: Character? = line
                        .split(separator: "[")
                        .first
                        .map { String($0) }?
                        .trimmingCharacters(in: .whitespaces)
                        .last
                    
                    switch lineEmoji {
                        case "💙": OWSLogger.verbose("Extension: \(String(line))")
                        case "💚": OWSLogger.debug("Extension: \(String(line))")
                        case "💛": OWSLogger.info("Extension: \(String(line))")
                        case "🧡": OWSLogger.warn("Extension: \(String(line))")
                        case "❤️": OWSLogger.error("Extension: \(String(line))")
                        default: OWSLogger.info("Extension: \(String(line))")
                    }
                }
                
                // Logs have been added - remove them now
                DDLog.flushLog()
                try? FileManager.default.removeItem(atPath: logFilePath)
            }
        }
    }
}
