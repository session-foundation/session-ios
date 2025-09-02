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
                Section {
                    SectionHeader(section: section.model)
                    
                    VStack(spacing: 0) {
                        ForEach(section.elements.indices, id: \.self) { index in
                            let element = section.elements[index]
                            let isLastElement: Bool = (index == section.elements.count - 1)
                            switch element.variant {
                                case .cell(let info):
                                    ListItemCell(info: info, height: section.model.style.height)
                                        .onTapGesture {
                                            element.onTap?()
                                        }
                                        .padding(.vertical, 8)
                                        .padding(.top, (index == 0) ? 8 : 0)
                                        .padding(.bottom, isLastElement ? 8 : 0)
                                        .background(
                                            Rectangle()
                                                .foregroundColor(themeColor: .backgroundSecondary)
                                        )
                                    
                                if (section.model.divider && !isLastElement) {
                                    Divider()
                                        .foregroundColor(themeColor: .borderSeparator)
                                        .padding(.horizontal, 16)
                                }
                                case .logoWithPro:
                                    ListItemLogWithPro()
                                case .dataMatrix(let info):
                                    ListItemDataMatrix(info: info)
                                        .onTapGesture {
                                            element.onTap?()
                                        }
                                        .background(
                                            Rectangle()
                                                .foregroundColor(themeColor: .backgroundSecondary)
                                        )
                            }
                        }
                    }
                    .cornerRadius(11)
                    .padding(.vertical, 8)
                    .listRowInsets(.init(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .listRowBackground(Color.clear)
                }
                .listRowSeparator(.hidden)
                .listSectionSeparator(.hidden)
            }
        }
        .listStyle(.inset)
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
