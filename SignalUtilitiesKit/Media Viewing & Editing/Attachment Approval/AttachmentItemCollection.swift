//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.

import UIKit
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

class SignalAttachmentItem: Equatable {

    enum SignalAttachmentItemError: Error {
        case noThumbnail
    }

    let uniqueIdentifier: UUID = UUID()
    let attachment: SignalAttachment

    // This might be nil if the attachment is not a valid image.
    var imageEditorModel: ImageEditorModel?

    init(attachment: SignalAttachment, using dependencies: Dependencies) {
        self.attachment = attachment

        // Try and make a ImageEditorModel.
        // This will only apply for valid images.
        if ImageEditorModel.isFeatureEnabled,
            let dataUrl: URL = attachment.dataUrl,
            dataUrl.isFileURL {
            let path = dataUrl.path
            do {
                imageEditorModel = try ImageEditorModel(srcImagePath: path, using: dependencies)
            } catch {
                // Usually not an error; this usually indicates invalid input.
                Log.warn("[SignalAttachmentItem] Could not create image editor: \(error)")
            }
        }
    }

    // MARK: 

    var captionText: String? {
        return attachment.captionText
    }

    func getThumbnailImage(using dependencies: Dependencies) -> UIImage? {
        return attachment.staticThumbnail(using: dependencies)
    }

    // MARK: Equatable

    static func == (lhs: SignalAttachmentItem, rhs: SignalAttachmentItem) -> Bool {
        return lhs.attachment == rhs.attachment
    }
}

// MARK: -

class AttachmentItemCollection {
    private(set) var attachmentItems: [SignalAttachmentItem]
    let isAddMoreVisible: Bool
    init(attachmentItems: [SignalAttachmentItem], isAddMoreVisible: Bool) {
        self.attachmentItems = attachmentItems
        self.isAddMoreVisible = isAddMoreVisible
    }

    func itemAfter(item: SignalAttachmentItem) -> SignalAttachmentItem? {
        guard let currentIndex = attachmentItems.firstIndex(of: item) else {
            Log.error("[AttachmentItemCollection] itemAfter currentIndex was unexpectedly nil.")
            return nil
        }

        let nextIndex = attachmentItems.index(after: currentIndex)

        return attachmentItems[safe: nextIndex]
    }

    func itemBefore(item: SignalAttachmentItem) -> SignalAttachmentItem? {
        guard let currentIndex = attachmentItems.firstIndex(of: item) else {
            Log.error("[AttachmentItemCollection] itemBefore currentIndex was unexpectedly nil.")
            return nil
        }

        let prevIndex = attachmentItems.index(before: currentIndex)

        return attachmentItems[safe: prevIndex]
    }

    func remove(item: SignalAttachmentItem) {
        attachmentItems = attachmentItems.filter { $0 != item }
    }

    var count: Int {
        return attachmentItems.count
    }
}
