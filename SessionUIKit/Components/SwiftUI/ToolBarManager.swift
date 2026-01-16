// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Lucide

// MARK: - Toolbar Manager

class ToolbarManager: ObservableObject {
    @Published var hasCloseButton: Bool
    var closeAction: () -> Void
    
    init(hasCloseButton: Bool = true, closeAction: @escaping () -> Void = {}) {
        self.hasCloseButton = hasCloseButton
        self.closeAction = closeAction
    }
    
    func close() {
        closeAction()
    }
    
    func setCloseAction(_ action: @escaping () -> Void) {
        closeAction = action
    }
}

// MARK: - Reusable Toolbar Modifier

struct PersistentCloseToolbarModifier: ViewModifier {
    @EnvironmentObject var toolbarManager: ToolbarManager
    
    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        toolbarManager.close()
                    } label: {
                        AttributedText(Lucide.Icon.x.attributedString(size: 28))
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(themeColor: .textPrimary)
                    }
                }
            }
    }
}

// MARK: - View Extension

public extension View {
    func persistentCloseToolbar() -> some View {
        modifier(PersistentCloseToolbarModifier())
    }
}
