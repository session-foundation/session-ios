// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionUtilitiesKit

protocol ApprovalRailCellViewDelegate: AnyObject {
    func approvalRailCellView(_ approvalRailCellView: ApprovalRailCellView, didRemoveItem attachmentItem: PendingAttachmentRailItem)
    func canRemoveApprovalRailCellView(_ approvalRailCellView: ApprovalRailCellView) -> Bool
}

// MARK: -

public class ApprovalRailCellView: GalleryRailCellView {

    weak var approvalRailCellDelegate: ApprovalRailCellViewDelegate?

    lazy var deleteButton: UIButton = {
        let button = OWSButton { [weak self] in
            guard let self = self else { return }

            guard let attachmentItem = item as? PendingAttachmentRailItem else {
                Log.error("[ApprovalRailCellView] attachmentItem was unexpectedly nil")
                return
            }

            self.approvalRailCellDelegate?.approvalRailCellView(self, didRemoveItem: attachmentItem)
        }

        button.setImage(UIImage(named: "x-24")?.withRenderingMode(.alwaysTemplate), for: .normal)
        button.themeTintColor = .white
        button.themeShadowColor = .black
        button.layer.shadowRadius = 2
        button.layer.shadowOpacity = 0.66
        button.layer.shadowOffset = .zero
        button.set(.width, to: 24)
        button.set(.height, to: 24)

        return button
    }()

    override func setIsSelected(_ isSelected: Bool) {
        super.setIsSelected(isSelected)

        if isSelected {
            if let approvalRailCellDelegate = self.approvalRailCellDelegate,
                approvalRailCellDelegate.canRemoveApprovalRailCellView(self) {

                addSubview(deleteButton)
                deleteButton.pin(.top, to: .top, of: self, withInset: cellBorderWidth)
                deleteButton.pin(.trailing, to: .trailing, of: self, withInset: -(cellBorderWidth + 4))
            }
        } else {
            deleteButton.removeFromSuperview()
        }
    }
}
