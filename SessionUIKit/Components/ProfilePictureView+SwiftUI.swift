// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

struct ProfilePictureView_SwiftUI: UIViewRepresentable {
//    typealias UIViewType = ProfilePictureView
    
    @Binding var info: ProfilePictureView.Info
    @Binding var additionalInfo: ProfilePictureView.Info?
    
    var size: ProfilePictureView.Size
    
    func makeUIView(context: Context) -> ProfilePictureView {
        ProfilePictureView(size: size)
    }
    
    func updateUIView(_ uiView: ProfilePictureView, context: Context) {
        uiView.update(
            info,
            additionalInfo: additionalInfo
        )
    }
}
