//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.

import UIKit
import SessionMessagingKit
import SessionUtilitiesKit

class AddMoreRailItem: GalleryRailItem {
    func buildRailItemView() -> UIView {
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

class SignalAttachmentItem: Hashable {

    enum SignalAttachmentItemError: Error {
        case noThumbnail
    }

    let uniqueIdentifier: UUID
    let attachment: SignalAttachment

    // This might be nil if the attachment is not a valid image.
    var imageEditorModel: ImageEditorModel?

    init(attachment: SignalAttachment) {
        self.attachment = attachment

        // Try and make a ImageEditorModel.
        // This will only apply for valid images.
        if ImageEditorModel.isFeatureEnabled,
            let dataUrl: URL = attachment.dataUrl,
            dataUrl.isFileURL {
            let path = dataUrl.path
            do {
                imageEditorModel = try ImageEditorModel(srcImagePath: path)
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

    func getThumbnailImage() -> UIImage? {
        return attachment.staticThumbnail()
    }

    // MARK: Hashable
    
    func hash(into hasher: inout Hasher) {
        /// There was a crash in `AttachmentApprovalViewController` when trying to generate the hash
        /// value to store in a dictionary, this crash persisted even after refactoring `DataSource` into Swift and
        /// using custom `hash(into:)` functions on everything in order to exclude values which might have
        /// been unsafe.
        ///
        /// Since the crash is still occurring the most likely culprit is now that one of the values used to generate the
        /// hash was mutated after the value was stored (as `SignalAttachment` is a class and it was previously
        /// used for generating the hash) - in order to avoid this we now generate a `uniqueIdentifier` when
        /// initialising this type and use _only_ that for the hash (this `SignalAttachmentItem` is only used for
        /// the `AttachmentApprovalViewController` and based on it's usage we shouldn't run into issues
        /// with this hash not being deterministic
        ///
        /// If the crash still occurs it's likely a red herring and there is some other, larger, issue that is causing it
        uniqueIdentifier.hash(into: &hasher)
    }

    // MARK: Equatable

    static func == (lhs: SignalAttachmentItem, rhs: SignalAttachmentItem) -> Bool {
        return lhs.attachment == rhs.attachment
    }
}

// MARK: -

class AttachmentItemCollection {
    private (set) var attachmentItems: [SignalAttachmentItem]
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
