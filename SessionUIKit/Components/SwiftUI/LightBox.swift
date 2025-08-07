// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

public struct LightBox<Content: View>: View {
    @Binding var isPresented: Bool
    
    public var title: String?
    public var itemsToShare: [Any] = []
    public var content: () -> Content
    
    public var body: some View {
        NavigationView {
            content()
                .navigationTitle(title ?? "")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            isPresented.toggle()
                        } label: {
                            Image(systemName: "chevron.left")
                                .foregroundColor(themeColor: .textPrimary)
                        }
                    }
                    
                    ToolbarItem(placement: .bottomBar) {
                        HStack {
                            Button {
                                share()
                            } label: {
                                Image(systemName: "square.and.arrow.up")
                                    .foregroundColor(themeColor: .textPrimary)
                            }
                            
                            Spacer()
                        }
                    }
                }
        }
    }
    
    private func share() {
        
    }
}
