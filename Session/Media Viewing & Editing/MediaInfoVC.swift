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
        
        attachments.forEach {
            let mediaPreviewView: MediaPreviewView = MediaPreviewView(
                attachment: $0,
                isOutgoing: isOutgoing)
            mediaStackView.addArrangedSubview(mediaPreviewView)
        }
        
        let contentWidth: CGFloat = Self.mediaSize * CGFloat(attachments.count)
        let contentHeight: CGFloat = Self.mediaSize
        mediaStackView.set(.width, to: contentWidth)
        mediaStackView.set(.height, to: contentHeight)
        
        let scrollView: UIScrollView = UIScrollView()
        scrollView.isPagingEnabled = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.set(.width, to: Self.mediaSize)
        scrollView.set(.height, to: Self.mediaSize)
        scrollView.contentSize = CGSize(width: contentWidth, height: contentHeight)
        scrollView.addSubview(mediaStackView)
        
        mediaInfoView.update(attachment: attachments[0])
        
        let stackView: UIStackView = UIStackView(arrangedSubviews: [ scrollView, mediaInfoView ])
        stackView.axis = .vertical
        stackView.spacing = Values.largeSpacing
        
        self.view.addSubview(stackView)
        stackView.center(in: self.view)
    }
}
