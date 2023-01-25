// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionUtilitiesKit

final class MediaInfoVC: BaseVC {
    internal static let mediaSize: CGFloat = 293
    
    private let attachments: [Attachment]
    private let isOutgoing: Bool
    
    // MARK: - UI
    private lazy var mediaInfoView: MediaInfoView = MediaInfoView(attachment: nil)
    private lazy var mediaCarouselView: SessionCarouselView = {
        let result: SessionCarouselView = SessionCarouselView(
            slices: self.attachments.map {
                MediaPreviewView(
                    attachment: $0,
                    isOutgoing: self.isOutgoing
                )
            },
            sliceSize: CGSize(
                width: Self.mediaSize,
                height: Self.mediaSize
            )
        )
        
        return result
    }()
    
    // MARK: - Initialization
    
    init(attachments: [Attachment], isOutgoing: Bool) {
        self.isOutgoing = isOutgoing
        self.attachments = attachments
        super.init(nibName: nil, bundle: nil)
    }

    override init(nibName: String?, bundle: Bundle?) {
        preconditionFailure("Use init(attachments:) instead.")
    }

    required init?(coder: NSCoder) {
        preconditionFailure("Use init(attachments:) instead.")
    }
    
    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        
        ViewControllerUtilities.setUpDefaultSessionStyle(
            for: self,
            title: "Message Info",
            hasCustomBackButton: false
        )
        
        let mediaStackView: UIStackView = UIStackView()
        mediaStackView.axis = .horizontal
        
        mediaInfoView.update(attachment: attachments[0])
        
        let stackView: UIStackView = UIStackView(arrangedSubviews: [ mediaCarouselView, mediaInfoView ])
        stackView.axis = .vertical
        stackView.spacing = Values.largeSpacing
        
        self.view.addSubview(stackView)
        stackView.center(in: self.view)
    }
}
