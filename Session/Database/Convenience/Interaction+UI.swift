// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Lucide
import SessionUIKit
import SessionMessagingKit

public extension Interaction.State {
    func statusIconInfo(
        variant: Interaction.Variant,
        hasBeenReadByRecipient: Bool,
        hasAttachments: Bool
    ) -> (image: UIImage?, text: String?, themeTintColor: ThemeValue) {
        guard variant == .standardOutgoing else {
            return (nil, nil, .messageBubble_deliveryStatus)
        }

        switch (self, hasBeenReadByRecipient, hasAttachments) {
            case (.deleted, _, _), (.localOnly, _, _):
                return (nil, nil, .messageBubble_deliveryStatus)
            
            case (.sending, _, true):
                return (
                    UIImage(systemName: "ellipsis.circle"),
                    "uploading".localized(),
                    .messageBubble_deliveryStatus
                )
                
            case (.sending, _, _):
                return (
                    UIImage(systemName: "ellipsis.circle"),
                    "sending".localized(),
                    .messageBubble_deliveryStatus
                )

            case (.sent, false, _):
                return (
                    Lucide.image(icon: .circleCheck, size: 12)?
                        .withRenderingMode(.alwaysTemplate),
                    "disappearingMessagesSent".localized(),
                    .messageBubble_deliveryStatus
                )

            case (.sent, true, _):
                return (
                    UIImage(systemName: "eye.fill"),
                    "read".localized(),
                    .messageBubble_deliveryStatus
                )
                
            case (.failed, _, _):
                return (
                    Lucide.image(icon: .triangleAlert, size: 12)?
                        .withRenderingMode(.alwaysTemplate),
                    "messageStatusFailedToSend".localized(),
                    .danger
                )
                
            case (.failedToSync, _, _):
                return (
                    Lucide.image(icon: .triangleAlert, size: 12)?
                        .withRenderingMode(.alwaysTemplate),
                    "messageStatusFailedToSync".localized(),
                    .warning
                )
                
            case (.syncing, _, _):
                return (
                    UIImage(systemName: "ellipsis.circle"),
                    "messageStatusSyncing".localized(),
                    .warning
                )

        }
    }
}
