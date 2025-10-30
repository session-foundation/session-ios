// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Lucide

public struct SessionProBottomSheet: View {
    @EnvironmentObject var host: HostWrapper
    
    let viewModel: any SessionProBottomSheetViewModelType
    let hasCloseButton: Bool
    let afterClosed: (() -> Void)?
    
    public init(
        viewModel: any SessionProBottomSheetViewModelType,
        hasCloseButton: Bool,
        afterClosed: (() -> Void)?
    ) {
        self.viewModel = viewModel
        self.hasCloseButton = hasCloseButton
        self.afterClosed = afterClosed
    }
    
    public var body: some View {
        
    }
}
