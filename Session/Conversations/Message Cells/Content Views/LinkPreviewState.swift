// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

protocol LinkPreviewState {
    var isLoaded: Bool { get }
    var urlString: String? { get }
    var title: String? { get }
    var imageState: LinkPreview.ImageState { get }
    var imageSource: ImageDataManager.DataSource? { get }
}

public extension LinkPreview {
    enum ImageState: Int {
        case none
        case loading
        case loaded
        case invalid
    }
    
    // MARK: LoadingState
    
    struct LoadingState: LinkPreviewState {
        var isLoaded: Bool { false }
        var urlString: String? { nil }
        var title: String? { nil }
        var imageState: LinkPreview.ImageState { .none }
        var imageSource: ImageDataManager.DataSource? { nil }
    }
    
    // MARK: DraftState
    
    struct DraftState: LinkPreviewState {
        var isLoaded: Bool { true }
        var urlString: String? { linkPreviewDraft.urlString }

        var title: String? {
            guard let value = linkPreviewDraft.title, value.count > 0 else { return nil }
            
            return value
        }
        
        var imageState: LinkPreview.ImageState {
            if linkPreviewDraft.imageSource != nil { return .loaded }
            
            return .none
        }
        
        var imageSource: ImageDataManager.DataSource? { linkPreviewDraft.imageSource }
        
        // MARK: - Type Specific
        
        private let linkPreviewDraft: LinkPreviewDraft
        
        // MARK: - Initialization

        init(linkPreviewDraft: LinkPreviewDraft) {
            self.linkPreviewDraft = linkPreviewDraft
        }
    }
    
    // MARK: - SentState
    
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
