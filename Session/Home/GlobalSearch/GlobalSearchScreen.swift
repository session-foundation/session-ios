// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit
import SignalUtilitiesKit
import SignalCoreKit

struct GlobalSearchScreen: View {
    fileprivate typealias SectionModel = ArraySection<SearchSection, SessionThreadViewModel>

    enum SearchSection: Int, Differentiable {
        case noResults
        case contactsAndGroups
        case messages
    }
    
    @EnvironmentObject var host: HostWrapper
    
    @State var searchText: String = ""
    @State private var searchResultSet: [SectionModel] = []
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(
                    alignment: .leading,
                    spacing: Values.smallSpacing
                ) {
                    SessionSearchBar(
                        searchText: $searchText.onChange{ updatedSearchText in 
                            onSearchTextChange(updatedSearchText: updatedSearchText)
                        },
                        cancelAction: {
                            self.host.controller?.navigationController?.popViewController(animated: true)
                        }
                    )
                    
                    
                }
            }
        }
        .backgroundColor(themeColor: .backgroundPrimary)
    }
    
    func onSearchTextChange(updatedSearchText: String) {
        guard updatedSearchText != searchText else { return }
        
    }
}

#Preview {
    GlobalSearchScreen()
}
