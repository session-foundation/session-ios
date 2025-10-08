//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.

import UIKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

class AddMoreRailItem: GalleryRailItem {
    func buildRailItemView(using dependencies: Dependencies) -> UIView {
        let view = UIView()
        view.themeBackgroundColor = .backgroundSecondary

        let iconView = UIImageView(image: #imageLiteral(resourceName: "ic_plus_24").withRenderingMode(.alwaysTemplate))
        iconView.themeTintColor = .textPrimary
        view.addSubview(iconView)
        iconView.center(in: view)
        iconView.setContentHugging(to: .required)
        iconView.setCompressionResistance(to: .required)

        return view
    }
    
    func isEqual(to other: GalleryRailItem?) -> Bool {
        return (other is AddMoreRailItem)
    }
}

class PendingAttachmentRailItem: Equatable {

    enum PendingAttachmentRailItemError: Error {
        case noThumbnail
    }

    let uniqueIdentifier: UUID = UUID()
    let attachment: PendingAttachment

    // This might be nil if the attachment is not a valid image.
    var imageEditorModel: ImageEditorModel?

    init(attachment: PendingAttachment, using dependencies: Dependencies) {
        self.attachment = attachment

        // Try and make a ImageEditorModel.
        // This will only apply for valid images.
        if
            ImageEditorModel.isFeatureEnabled &&
            attachment.utType.isImage &&
            attachment.duration == 0,
            case .media(let mediaSource) = attachment.source,
            case .url = mediaSource
        {
            do {
                imageEditorModel = try ImageEditorModel(attachment: attachment, using: dependencies)
            } catch {
                // Usually not an error; this usually indicates invalid input.
                Log.warn("[PendingAttachmentRailItem] Could not create image editor: \(error)")
            }
        }
    }

    // MARK: Equatable

    static func == (lhs: PendingAttachmentRailItem, rhs: PendingAttachmentRailItem) -> Bool {
        return lhs.attachment == rhs.attachment
    }
}

// MARK: -

class PendingAttachmentRailItemCollection {
    private(set) var attachmentItems: [PendingAttachmentRailItem]
    let isAddMoreVisible: Bool
    init(attachmentItems: [PendingAttachmentRailItem], isAddMoreVisible: Bool) {
        self.attachmentItems = attachmentItems
        self.isAddMoreVisible = isAddMoreVisible
    }

    func itemAfter(item: PendingAttachmentRailItem) -> PendingAttachmentRailItem? {
        guard let currentIndex = attachmentItems.firstIndex(of: item) else {
            Log.error("[AttachmentItemCollection] itemAfter currentIndex was unexpectedly nil.")
            return nil
        }

        let nextIndex = attachmentItems.index(after: currentIndex)

        return attachmentItems[safe: nextIndex]
    }

    func itemBefore(item: PendingAttachmentRailItem) -> PendingAttachmentRailItem? {
        guard let currentIndex = attachmentItems.firstIndex(of: item) else {
            Log.error("[AttachmentItemCollection] itemBefore currentIndex was unexpectedly nil.")
            return nil
        }

        let prevIndex = attachmentItems.index(before: currentIndex)

        return attachmentItems[safe: prevIndex]
    }

    func remove(item: PendingAttachmentRailItem) {
        attachmentItems = attachmentItems.filter { $0 != item }
    }

    var count: Int {
        return attachmentItems.count
    }
}
