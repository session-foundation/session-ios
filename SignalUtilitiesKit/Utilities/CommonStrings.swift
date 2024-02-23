//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

import Foundation

/**
 * Strings re-used in multiple places should be added here.
 */

@objc public class CommonStrings: NSObject {
    @objc
    static public let dismissButton = NSLocalizedString("dismiss", comment: "Short text to dismiss current modal / actionsheet / screen")
    @objc
    static public let cancelButton = NSLocalizedString("cancel", comment: "Label for the cancel button in an alert or action sheet.")
    @objc
    static public let doneButton = NSLocalizedString("done", comment: "Label for generic done button.")
    @objc
    static public let retryButton = "retry".localized()
    @objc
    static public let openSettingsButton = NSLocalizedString("sessionSettings", comment: "Button text which opens the settings app")
    @objc
    static public let errorAlertTitle = NSLocalizedString("error", comment: "")
}

@objc public class MessageStrings: NSObject {
    @objc
    static public let replyNotificationAction = NSLocalizedString("reply", comment: "Notification action button title")

    @objc
    static public let markAsReadNotificationAction = NSLocalizedString("messageMarkRead", comment: "Notification action button title")

    @objc
    static public let sendButton = "send".localized()
}

@objc
public class NotificationStrings: NSObject {
    @objc
    static public let incomingMessageBody = NSLocalizedString("messageNewYouveGotA", comment: "notification body")
    
    @objc
    static public let incomingCollapsedMessagesBody = NSLocalizedString("messageNewYouveGotMany", comment: "collapsed notification body for background polling")

    @objc
    static public let incomingGroupMessageTitleFormat = NSLocalizedString("notificationsIosGroup", comment: "notification title. Embeds {{author name}} and {{group name}}")

    @objc
    static public let failedToSendBody = "messageErrorDelivery".localized()
}

@objc public class MediaStrings: NSObject {
    @objc
    static public let allMedia = NSLocalizedString("conversationsSettingsAllMedia", comment: "nav bar button item")
    @objc
    static public let media = NSLocalizedString("media", comment: "media tab title")
    @objc
    static public let document = NSLocalizedString("DOCUMENT_TAB_TITLE", comment: "document tab title")
}
