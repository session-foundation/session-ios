// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

public extension LinkPreview {
    func sentState(
        imageAttachment: Attachment?,
        using dependencies: Dependencies
    ) -> LinkPreviewViewModel {
        return LinkPreviewViewModel(
            state: .sent,
            urlString: url,
            title: (title?.isEmpty == false ? title : nil),
            imageSource: {
                /// **Note:** We don't check if the image is valid here because that can be confirmed in 'imageState' and it's a
                /// little inefficient
                guard
                    imageAttachment?.isImage == true,
                    let imageDownloadUrl: String = imageAttachment?.downloadUrl,
                    let path: String = try? dependencies[singleton: .attachmentManager]
                        .path(for: imageDownloadUrl)
                else { return nil }
                
                return .url(URL(fileURLWithPath: path))
            }()
        )
    }
}
