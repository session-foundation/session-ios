// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit
import SignalUtilitiesKit
import SignalCoreKit
import SwipeActions

enum SearchSection: Int, Differentiable {
    case noResults
    case contactsAndGroups
    case messages
    case defaultContacts
}

struct GlobalSearchScreen: View {
    fileprivate typealias SectionModel = ArraySection<SearchSection, SessionThreadViewModel>
    
    struct SectionData {
            var sectionName: String
            var contacts: [SessionThreadViewModel]
        }

    @EnvironmentObject var host: HostWrapper
    
    @State private var searchText: String = ""
    @State private var searchResultSet: [SectionModel] = Self.defaultSearchResults
    @State private var readConnection: Atomic<Database?> = Atomic(nil)
    @State private var termForCurrentSearchResultSet: String = ""
    @State private var lastSearchText: String?
    @State private var swipeState: SwipeActions.SwipeState = .untouched
    
    fileprivate static var defaultSearchResults: [SectionModel] = {
        let result: [SessionThreadViewModel]? = Storage.shared.read { db -> [SessionThreadViewModel]? in
            try SessionThreadViewModel
                .defaultContactsQuery(userPublicKey: getUserHexEncodedPublicKey(db))
                .fetchAll(db)
        }
        
        return [ result.map { ArraySection(model: .defaultContacts, elements: $0) } ]
            .compactMap { $0 }
    }()
    
    fileprivate var defaultGroupedContacts: [SectionData] = {
        let contacts = Self.defaultSearchResults[0].elements
        var groupedContacts: [String: SectionData] = [:]
        contacts.forEach { contactViewModel in
            guard !contactViewModel.threadIsNoteToSelf else {
                groupedContacts[""] = SectionData(
                    sectionName: "",
                    contacts: [contactViewModel]
                )
                return
            }
            
            let displayName = NSMutableString(string: contactViewModel.displayName)
            CFStringTransform(displayName, nil, kCFStringTransformToLatin, false)
            CFStringTransform(displayName, nil, kCFStringTransformStripDiacritics, false)
                
            let initialCharacter: String = (displayName.length > 0 ? displayName.substring(to: 1) : "")
            let section: String = initialCharacter.capitalized.isSingleAlphabet ?
                initialCharacter.capitalized :
                "Unknown"
                
            if groupedContacts[section] == nil {
                groupedContacts[section] = SectionData(
                    sectionName: section,
                    contacts: []
                )
            }
            groupedContacts[section]?.contacts.append(contactViewModel)
        }
        
        return groupedContacts.values.sorted {
            if  $0.sectionName.count != $1.sectionName.count {
                return $0.sectionName.count < $1.sectionName.count
            }
            return $0.sectionName < $1.sectionName
        }
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
            
            CompatibleScrollingVStack(
                alignment: .leading
            ) {
                ForEach(0..<searchResultSet.count, id: \.self) { sectionIndex in
                    let section = searchResultSet[sectionIndex]
                    switch section.model {
                        case .noResults:
                            Text("CONVERSATION_SEARCH_NO_RESULTS".localized())
                                .font(.system(size: Values.mediumFontSize))
                                .foregroundColor(themeColor: .textPrimary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 150)
                        case .contactsAndGroups, .messages:
                            if section.elements.count > 0 {
                                let sectionTitle: String = section.model == .contactsAndGroups ? "CONVERSATION_SETTINGS_TITLE".localized() : "SEARCH_SECTION_MESSAGES".localized()
                                Section(
                                    header: Text(sectionTitle)
                                        .bold()
                                        .font(.system(size: Values.mediumLargeFontSize))
                                        .foregroundColor(themeColor: .textPrimary)
                                        .padding(.horizontal, Values.mediumSpacing + Values.verySmallSpacing)
                                        .padding(.top, Values.verySmallSpacing)
                                ) {
                                    ForEach(0..<section.elements.count, id: \.self) { rowIndex in
                                        let rowViewModel = section.elements[rowIndex]
                                        SearchResultCell(
                                            searchText: searchText,
                                            searchSection: section.model,
                                            viewModel: rowViewModel
                                        ) {
                                            show(
                                                threadId: rowViewModel.threadId,
                                                threadVariant: rowViewModel.threadVariant,
                                                focusedInteractionInfo: {
                                                    guard
                                                        let interactionId: Int64 = rowViewModel.interactionId,
                                                        let timestampMs: Int64 = rowViewModel.interactionTimestampMs
                                                    else { return nil }
                                                    
                                                    return Interaction.TimestampInfo(
                                                        id: interactionId,
                                                        timestampMs: timestampMs
                                                    )
                                                }()
                                            )
                                        }
                                    }
                                }
                            }
                        case .defaultContacts:
                            Section(
                                header: Text("NEW_CONVERSATION_CONTACTS_SECTION_TITLE".localized())
                                    .bold()
                                    .font(.system(size: Values.mediumLargeFontSize))
                                    .foregroundColor(themeColor: .textPrimary)
                                    .padding(.horizontal, Values.mediumSpacing + Values.verySmallSpacing)
                                    .padding(.top, Values.verySmallSpacing)
                            ) {
                                ForEach(0..<defaultGroupedContacts.count, id: \.self) { groupIndex in
                                    let sectionData = defaultGroupedContacts[groupIndex]
                                    
                                    Section(
                                        header: Group{
                                            if !sectionData.sectionName.isEmpty {
                                                Text(sectionData.sectionName)
                                                    .font(.system(size: Values.smallFontSize))
                                                    .foregroundColor(themeColor: .textPrimary)
                                                    .padding(.horizontal, Values.mediumSpacing + Values.verySmallSpacing)
                                                    .padding(.top, Values.verySmallSpacing)
                                            }
                                        }
                                    ) {
                                        ForEach(0..<sectionData.contacts.count, id: \.self) { rowIndex in
                                            let rowViewModel = sectionData.contacts[rowIndex]
                                            SearchResultCell(
                                                searchText: searchText,
                                                searchSection: section.model,
                                                viewModel: rowViewModel
                                            ) {
                                                show(
                                                    threadId: rowViewModel.threadId,
                                                    threadVariant: rowViewModel.threadVariant,
                                                    focusedInteractionInfo: {
                                                        guard
                                                            let interactionId: Int64 = rowViewModel.interactionId,
                                                            let timestampMs: Int64 = rowViewModel.interactionTimestampMs
                                                        else { return nil }
                                                        
                                                        return Interaction.TimestampInfo(
                                                            id: interactionId,
                                                            timestampMs: timestampMs
                                                        )
                                                    }()
                                                )
                                            }
                                            .addSwipeAction(
                                                edge: .trailing,
                                                state: $swipeState
                                            ) {
                                                Button {
                                                    
                                                } label: {
                                                    VStack {
                                                        Image("icon_bin")
                                                            .renderingMode(.template)
                                                            .foregroundColor(themeColor: .textPrimary)
                                                        Text("TXT_DELETE_TITLE".localized())
                                                            .foregroundColor(themeColor: .textPrimary)
                                                    }
                                                }
                                                .frame(width: 60)
                                                .frame(maxHeight: .infinity)
                                                .contentShape(Rectangle())
                                                .backgroundColor(themeColor: .danger)
                                            }
                                            
                                            
                                            Text("Text")
                                                .addSwipeAction(
                                                    edge: .trailing,
                                                    state: $swipeState
                                                ) {
                                                    Button {
                                                        
                                                    } label: {
                                                        VStack {
                                                            Image("icon_bin")
                                                                .renderingMode(.template)
                                                                .foregroundColor(themeColor: .textPrimary)
                                                            Text("TXT_DELETE_TITLE".localized())
                                                                .font(.system(size: Values.mediumFontSize))
                                                                .foregroundColor(themeColor: .textPrimary)
                                                        }
                                                    }
                                                    .frame(width: 100)
                                                    .frame(maxHeight: .infinity)
                                                    .contentShape(Rectangle())
                                                    .backgroundColor(themeColor: .danger)
                                                }
                                        }
                                    }
                                }
                            }
                    }
                }
            }
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
                    let contactsResults: [SessionThreadViewModel] = try SessionThreadViewModel
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
                        ArraySection(model: .contactsAndGroups, elements: contactsResults),
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
                        
                    default: break
                }
            }
        }
    }
    
    private func show(threadId: String, threadVariant: SessionThread.Variant, focusedInteractionInfo: Interaction.TimestampInfo? = nil, animated: Bool = true) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.show(threadId: threadId, threadVariant: threadVariant, focusedInteractionInfo: focusedInteractionInfo, animated: animated)
            }
            return
        }
        
        // If it's a one-to-one thread then make sure the thread exists before pushing to it (in case the
        // contact has been hidden)
        if threadVariant == .contact {
            Storage.shared.write { db in
                try SessionThread.fetchOrCreate(
                    db,
                    id: threadId,
                    variant: threadVariant,
                    shouldBeVisible: nil    // Don't change current state
                )
            }
        }
        
        let viewController: ConversationVC = ConversationVC(
            threadId: threadId,
            threadVariant: threadVariant,
            focusedInteractionInfo: focusedInteractionInfo
        )
        self.host.controller?.navigationController?.pushViewController(viewController, animated: true)
    }
}

struct SearchResultCell: View {
    var searchText: String
    var searchSection: SearchSection
    var viewModel: SessionThreadViewModel
    var action: () -> Void
    
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
            .padding(.vertical, Values.smallSpacing)
            
            VStack(
                alignment: .leading,
                spacing: Values.verySmallSpacing
            ) {
                HStack {
                    Text(viewModel.displayName)
                        .bold()
                        .font(.system(size: Values.mediumFontSize))
                        .foregroundColor(themeColor: .textPrimary)
                    
                    Spacer()
                    
                    if searchSection == .messages {
                        Text(viewModel.lastInteractionDate.formattedForDisplay)
                            .font(.system(size: Values.smallFontSize))
                            .foregroundColor(themeColor: .textSecondary)
                            .opacity(Values.lowOpacity)
                    }
                }
                
                if let textColor: UIColor = ThemeManager.currentTheme.color(for: .textPrimary) {
                    let maybeSnippet: NSAttributedString? = {
                        switch searchSection {
                            case .noResults, .defaultContacts:
                                return nil
                            case .contactsAndGroups:
                                switch viewModel.threadVariant {
                                    case .contact, .community: return nil
                                    case .legacyGroup, .group:
                                        return self.getHighlightedSnippet(
                                            content: (viewModel.threadMemberNames ?? ""),
                                            currentUserPublicKey: viewModel.currentUserPublicKey,
                                            currentUserBlinded15PublicKey: viewModel.currentUserBlinded15PublicKey,
                                            currentUserBlinded25PublicKey: viewModel.currentUserBlinded25PublicKey,
                                            searchText: searchText.lowercased(),
                                            fontSize: Values.smallFontSize,
                                            textColor: textColor
                                        )
                                }
                            case .messages:
                                return self.getHighlightedSnippet(
                                    content: Interaction.previewText(
                                        variant: (viewModel.interactionVariant ?? .standardIncoming),
                                        body: viewModel.interactionBody,
                                        authorDisplayName: viewModel.authorName(for: .contact),
                                        attachmentDescriptionInfo: viewModel.interactionAttachmentDescriptionInfo,
                                        attachmentCount: viewModel.interactionAttachmentCount,
                                        isOpenGroupInvitation: (viewModel.interactionIsOpenGroupInvitation == true)
                                    ),
                                    authorName: (viewModel.authorId != viewModel.currentUserPublicKey ?
                                        viewModel.authorName(for: .contact) :
                                        nil
                                    ),
                                    currentUserPublicKey: viewModel.currentUserPublicKey,
                                    currentUserBlinded15PublicKey: viewModel.currentUserBlinded15PublicKey,
                                    currentUserBlinded25PublicKey: viewModel.currentUserBlinded25PublicKey,
                                    searchText: searchText.lowercased(),
                                    fontSize: Values.smallFontSize,
                                    textColor: textColor
                                )
                            }
                    }()
                    
                    if let snippet = maybeSnippet {
                        AttributedText(snippet).lineLimit(1)
                    }
                }
            }
            
            Spacer(minLength: 0)
        }
        .padding(.leading, Values.mediumSpacing)
        .contentShape(Rectangle())
        .onTapGesture {
            action()
        }
    }
    
    private func getHighlightedSnippet(
        content: String,
        authorName: String? = nil,
        currentUserPublicKey: String,
        currentUserBlinded15PublicKey: String?,
        currentUserBlinded25PublicKey: String?,
        searchText: String,
        fontSize: CGFloat,
        textColor: UIColor
    ) -> NSAttributedString {
        guard !content.isEmpty, content != "NOTE_TO_SELF".localized() else {
            return NSMutableAttributedString(
                string: (authorName != nil && authorName?.isEmpty != true ?
                    "\(authorName ?? ""): \(content)" :
                    content
                ),
                attributes: [ .foregroundColor: textColor ]
            )
        }
        
        // Replace mentions in the content
        //
        // Note: The 'threadVariant' is used for profile context but in the search results
        // we don't want to include the truncated id as part of the name so we exclude it
        let mentionReplacedContent: String = MentionUtilities.highlightMentionsNoAttributes(
            in: content,
            threadVariant: .contact,
            currentUserPublicKey: currentUserPublicKey,
            currentUserBlinded15PublicKey: currentUserBlinded15PublicKey,
            currentUserBlinded25PublicKey: currentUserBlinded25PublicKey
        )
        let result: NSMutableAttributedString = NSMutableAttributedString(
            string: mentionReplacedContent,
            attributes: [
                .foregroundColor: textColor
                    .withAlphaComponent(Values.lowOpacity)
            ]
        )
        
        // Bold each part of the searh term which matched
        let normalizedSnippet: String = mentionReplacedContent.lowercased()
        var firstMatchRange: Range<String.Index>?
        
        SessionThreadViewModel.searchTermParts(searchText)
            .map { part -> String in
                guard part.hasPrefix("\"") && part.hasSuffix("\"") else { return part }
                
                return part.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            .forEach { part in
                // Highlight all ranges of the text (Note: The search logic only finds results that start
                // with the term so we use the regex below to ensure we only highlight those cases)
                normalizedSnippet
                    .ranges(
                        of: (Singleton.appContext.isRTL ?
                             "(\(part.lowercased()))(^|[^a-zA-Z0-9])" :
                             "(^|[^a-zA-Z0-9])(\(part.lowercased()))"
                        ),
                        options: [.regularExpression]
                    )
                    .forEach { range in
                        let targetRange: Range<String.Index> = {
                            let term: String = String(normalizedSnippet[range])
                            
                            // If the matched term doesn't actually match the "part" value then it means
                            // we've matched a term after a non-alphanumeric character so need to shift
                            // the range over by 1
                            guard term.starts(with: part.lowercased()) else {
                                return (normalizedSnippet.index(after: range.lowerBound)..<range.upperBound)
                            }
                            
                            return range
                        }()
                        
                        // Store the range of the first match so we can focus it in the content displayed
                        if firstMatchRange == nil {
                            firstMatchRange = targetRange
                        }
                        
                        let legacyRange: NSRange = NSRange(targetRange, in: normalizedSnippet)
                        result.addAttribute(.foregroundColor, value: textColor, range: legacyRange)
                        result.addAttribute(.font, value: UIFont.boldSystemFont(ofSize: fontSize), range: legacyRange)
                    }
            }
        
        // Now that we have generated the focused snippet add the author name as a prefix (if provided)
        return authorName
            .map { authorName -> NSAttributedString? in
                guard !authorName.isEmpty else { return nil }
                
                let authorPrefix: NSAttributedString = NSAttributedString(
                    string: "\(authorName): ",
                    attributes: [ .foregroundColor: textColor ]
                )
                
                return authorPrefix.appending(result)
            }
            .defaulting(to: result)
    }
}

#Preview {
    GlobalSearchScreen()
}
