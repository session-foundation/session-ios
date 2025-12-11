// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Lucide

public enum NotificationsUI {
    public static let mutePrefix: Lucide.Icon = Lucide.Icon.volumeX
    public static let mentionPrefix: Lucide.Icon = Lucide.Icon.atSign
}

public extension ThemedAttributedString {
    func stylingNotificationPrefixesIfNeeded(fontSize: CGFloat) -> ThemedAttributedString {
        if self.string.starts(with: NotificationsUI.mutePrefix.rawValue) {
            return addingAttributes(
                Lucide.attributes(for: .systemFont(ofSize: fontSize)),
                range: NSRange(location: 0, length: NotificationsUI.mutePrefix.rawValue.count)
            )
        }
        else if self.string.starts(with: NotificationsUI.mentionPrefix.rawValue) {
            let imageAttachment: NSTextAttachment = NSTextAttachment()
            imageAttachment.image = UIImage(named: "NotifyMentions.png")?
                .withRenderingMode(.alwaysTemplate)
            imageAttachment.bounds = CGRect(
                x: 0,
                y: -2,
                width: fontSize,
                height: fontSize
            )
            
            return self.replacingCharacters(
                in: NSRange(location: 0, length: NotificationsUI.mutePrefix.rawValue.count),
                with: NSAttributedString(attachment: imageAttachment)
            )
        }
        
        return self
    }
}
