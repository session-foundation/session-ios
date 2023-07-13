// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

public struct ProfilePictureSwiftUI: UIViewRepresentable {
    public typealias UIViewType = ProfilePictureView

    var size: ProfilePictureView.Size
    
    public init(size: ProfilePictureView.Size) {
        self.size = size
    }
    
    public func makeUIView(context: Context) -> ProfilePictureView {
        ProfilePictureView(size: size)
    }
    
    public func updateUIView(_ uiView: ProfilePictureView, context: Context) {

    }
}
