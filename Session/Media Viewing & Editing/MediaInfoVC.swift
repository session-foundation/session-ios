// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionUtilitiesKit

final class MediaInfoVC: BaseVC {
    
    private let attachments: [Attachment]
    private let isOutgoing: Bool
    
    // FIXME: Would be good to create a Swift-based cache and replace this
    lazy var mediaCache: NSCache<NSString, AnyObject> = {
        let result = NSCache<NSString, AnyObject>()
        result.countLimit = 40
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
        
        self.title = "Message Info"
        
        attachments.forEach {
            let mediaPreviewView: MediaPreviewView = MediaPreviewView(
                mediaCache: mediaCache,
                attachment: $0,
                isOutgoing: isOutgoing)
            let mediaInfoView: MediaInfoView = MediaInfoView(attachment: $0)
            
            let stackView: UIStackView = UIStackView(arrangedSubviews: [ mediaPreviewView, mediaInfoView ])
            stackView.axis = .vertical
            stackView.spacing = Values.largeSpacing
            
            self.view.addSubview(stackView)
            stackView.center(in: self.view)
        }
    }
}
