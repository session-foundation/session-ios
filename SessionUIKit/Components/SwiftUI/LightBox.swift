// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

public struct LightBox<Content: View>: View {
    @EnvironmentObject var host: HostWrapper

    public var title: String?
    public var itemsToShare: [UIImage] = []
    public var content: () -> Content
    
    public init(title: String? = nil, itemsToShare: [UIImage], content: @escaping () -> Content) {
        self.title = title
        self.itemsToShare = itemsToShare
        self.content = content
    }
    
    public var body: some View {
        NavigationView {
            content()
                .navigationTitle(title ?? "")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            self.host.controller?.dismiss(animated: true)
                        } label: {
                            Image(systemName: "chevron.left")
                                .foregroundColor(themeColor: .textPrimary)
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    HStack {
                        Button {
                            share()
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 20))
                                .foregroundColor(themeColor: .textPrimary)
                        }

                        Spacer()
                    }
                    .padding()
                    .backgroundColor(themeColor: .backgroundSecondary)
                }
        }
    }
    
    private func share() {
        let shareVC: UIActivityViewController = UIActivityViewController(
            activityItems: itemsToShare,
            applicationActivities: nil
        )
        
        if UIDevice.current.isIPad {
            shareVC.popoverPresentationController?.permittedArrowDirections = []
            shareVC.popoverPresentationController?.sourceView = self.host.controller?.view
            shareVC.popoverPresentationController?.sourceRect = (self.host.controller?.view.bounds ?? UIScreen.main.bounds)
        }
        
        self.host.controller?.present(
            shareVC,
            animated: true
        )
    }
}
