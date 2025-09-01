// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

public struct SessionListScreen<ViewModel: SessionListScreenContent.ViewModelType>: View {
    @EnvironmentObject var host: HostWrapper
    @StateObject private var viewModel: ViewModel
    
    public init(viewModel: ViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }
    
    public var body: some View {
        List {
            ForEach(viewModel.state.listItemData, id: \.model) { section in 
                Section(header: SectionHeader(section: section.model)) {
                    ForEach(section.elements, id: \.id) { element in
                        switch element.variant {
                            case .cell(let info):
                                ListItemCell(info: info)
                            case .logoWithPro:
                                ListItemLogWithPro()
                            case .dataMatrix(let info):
                                ListItemDataMatrixInfo(info: info)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
    }
}

//#if DEBUG
//extension SessionListScreenContent {
//    class PreviewViewModel: ViewModelType {
//    }
//}
//
//#Preview {
//    SessionListScreen(
//        viewModel: SessionListScreenContent.PreviewViewModel()
//    )
//}
//#endif
