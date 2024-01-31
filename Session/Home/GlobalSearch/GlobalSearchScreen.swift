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
        case contacts
        case messages
    }
    
    @EnvironmentObject var host: HostWrapper
    
    @State private var searchText: String = ""
    @State private var searchResultSet: [SectionModel] = Self.defaultSearchResults
    @State private var readConnection: Atomic<Database?> = Atomic(nil)
    @State private var termForCurrentSearchResultSet: String = ""
    @State private var lastSearchText: String?
    @State private var isLoading = false
    
    fileprivate static var defaultSearchResults: [SectionModel] = {
        let result: SessionThreadViewModel? = Storage.shared.read { db -> SessionThreadViewModel? in
            try SessionThreadViewModel
                .noteToSelfOnlyQuery(userPublicKey: getUserHexEncodedPublicKey(db))
                .fetchOne(db)
        }
        
        return [ result.map { ArraySection(model: .contacts, elements: [$0]) } ]
            .compactMap { $0 }
    }()
    
    var body: some View {
        VStack(alignment: .leading) {
            SessionSearchBar(
                searchText: $searchText.onChange{ updatedSearchText in
                    onSearchTextChange(rawSearchText: updatedSearchText)
                },
                cancelAction: {
                    self.host.controller?.navigationController?.popViewController(animated: true)
                }
            )
            
            List{
                ForEach(0..<searchResultSet.count, id: \.self) { sectionIndex in
                    let section = searchResultSet[sectionIndex]
                    let sectionTitle: String = {
                        switch section.model {
                            case .noResults: return ""
                            case .contacts: return (section.elements.isEmpty ? "" : "NEW_CONVERSATION_CONTACTS_SECTION_TITLE".localized())
                            case .messages:return (section.elements.isEmpty ? "" : "SEARCH_SECTION_MESSAGES".localized())
                        }
                    }()
                    Section(
                        header: Text(sectionTitle)
                            .bold()
                            .font(.system(size: Values.mediumLargeFontSize))
                            .foregroundColor(themeColor: .textPrimary)
                    ) {
                        ForEach(0..<section.elements.count, id: \.self) { rowIndex in
                            let row = section.elements[rowIndex]
                            SearchResultCell(searchText: searchText, viewModel: row)
                        }
                    }
                }
            }
            .transparentScrolling()
            .listStyle(.plain)
            .padding(.top, -Values.mediumSpacing)
        }
        .backgroundColor(themeColor: .backgroundPrimary)
    }
    
    func onSearchTextChange(rawSearchText: String, force: Bool = false) {
        let searchText = rawSearchText.stripped
        
        guard searchText.count > 0 else {
            guard searchText != (lastSearchText ?? "") else { return }
            
            searchResultSet = Self.defaultSearchResults
            lastSearchText = nil
            return
        }
        guard force || lastSearchText != searchText else { return }

        lastSearchText = searchText
        
        DispatchQueue.global(qos: .default).async {
            self.readConnection.wrappedValue?.interrupt()
            
            let result: Result<[SectionModel], Error>? = Storage.shared.read { db -> Result<[SectionModel], Error> in
                self.readConnection.mutate { $0 = db }
                
                do {
                    let userPublicKey: String = getUserHexEncodedPublicKey(db)
                    let contactsResults: [SessionThreadViewModel] = try SessionThreadViewModel // TODO: Remove group search results
                        .contactsAndGroupsQuery(
                            userPublicKey: userPublicKey,
                            pattern: try SessionThreadViewModel.pattern(db, searchTerm: searchText),
                            searchTerm: searchText
                        )
                        .fetchAll(db)
                    let messageResults: [SessionThreadViewModel] = try SessionThreadViewModel
                        .messagesQuery(
                            userPublicKey: userPublicKey,
                            pattern: try SessionThreadViewModel.pattern(db, searchTerm: searchText)
                        )
                        .fetchAll(db)
                    
                    return .success([
                        ArraySection(model: .contacts, elements: contactsResults),
                        ArraySection(model: .messages, elements: messageResults)
                    ])
                }
                catch {
                    // Don't log the 'interrupt' error as that's just the user typing too fast
                    if (error as? DatabaseError)?.resultCode != DatabaseError.SQLITE_INTERRUPT {
                        SNLog("[GlobalSearch] Failed to find results due to error: \(error)")
                    }
                    
                    return .failure(error)
                }
            }
            
            DispatchQueue.main.async {
                switch result {
                    case .success(let sections):
                        let hasResults: Bool = (
                            !searchText.isEmpty &&
                            (sections.map { $0.elements.count }.reduce(0, +) > 0)
                        )
                        
                        self.termForCurrentSearchResultSet = searchText
                        self.searchResultSet = [
                            (hasResults ? nil : [
                                ArraySection(
                                    model: .noResults,
                                    elements: [
                                        SessionThreadViewModel(threadId: SessionThreadViewModel.invalidId)
                                    ]
                                )
                            ]),
                            (hasResults ? sections : nil)
                        ]
                        .compactMap { $0 }
                        .flatMap { $0 }
                        self.isLoading = false
                        
                    default: break
                }
            }
        }
        
    }
}

struct SearchResultCell: View {
    var searchText: String
    var viewModel: SessionThreadViewModel
    
    var body: some View {
        HStack(
            alignment: .center,
            spacing: Values.mediumSpacing
        ) {
            let size: ProfilePictureView.Size = .list
            
            ProfilePictureSwiftUI(
                size: size,
                publicKey: viewModel.threadId,
                threadVariant: viewModel.threadVariant,
                customImageData: viewModel.openGroupProfilePictureData,
                profile: viewModel.profile,
                additionalProfile: viewModel.additionalProfile
            )
            .frame(
                width: size.viewSize,
                height: size.viewSize,
                alignment: .topLeading
            )
            
            VStack(
                alignment: .leading,
                spacing: Values.verySmallSpacing
            ) {
                Text(viewModel.displayName)
                    .bold()
                    .font(.system(size: Values.mediumFontSize))
                    .foregroundColor(themeColor: .textPrimary)
            }
        }
    }
}

#Preview {
    GlobalSearchScreen()
}
