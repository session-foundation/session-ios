// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUIKit
import SessionUtilitiesKit

public enum GlobalSearch {}

// MARK: - Helper Functions

public extension GlobalSearch {
    private class SearchTermParts {
        let parts: [String]
        
        init(_ parts: [String]) {
            self.parts = parts
        }
    }
    
    static let searchResultsLimit: Int = 500
    private static let rangeOptions: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    private static let alphanumericSet: NSCharacterSet = (CharacterSet.alphanumerics as NSCharacterSet)
    private static let quoteCharacterSet: CharacterSet = CharacterSet(charactersIn: "\"")
    private static let searchTermPartRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "[^\\s\"']+|\"([^\"]*)\""  // stringlint:ignore
    )
    
    /// Processing a search term requires a little logic and regex execution and we need the processed version for every search result in
    /// order to properly highlight, as a result we cache the processed parts to avoid having to re-process.
    private static let searchTermPartCache: NSCache<NSString, SearchTermParts> = {
        let result: NSCache<NSString, SearchTermParts> = NSCache()
        result.name = "GlobalSearchTermPartsCache" // stringlint:ignore
        result.countLimit = 25  /// Last 25 search terms
        
        return result
    }()
    
    /// FTS will fail or try to process characters outside of `[A-Za-z0-9]` are included directly in a search
    /// term, in order to resolve this the term needs to be wrapped in quotation marks so the eventual SQL
    /// is `MATCH '"{term}"'` or `MATCH '"{term}"*'`
    static func searchSafeTerm(_ term: String) -> String {
        return "\"\(term)\""
    }
    
    // stringlint:ignore_contents
    static func searchTermParts(_ searchTerm: String) -> [String] {
        /// Process the search term in order to extract the parts of the search pattern we want
        ///
        /// Step 1 - Keep any "quoted" sections as stand-alone search
        /// Step 2 - Separate any words outside of quotes
        /// Step 3 - Join the different search term parts with 'OR" (include results for each individual term)
        /// Step 4 - Append a wild-card character to the final word (as long as the last word doesn't end in a quote)
        let normalisedTerm: String = standardQuotes(searchTerm)
        
        guard let regex: NSRegularExpression = searchTermPartRegex else {
            // Fallback to removing the quotes and just splitting on spaces
            return normalisedTerm
                .replacingOccurrences(of: "\"", with: "")
                .split(separator: " ")
                .map { "\"\($0)\"" }
                .filter { !$0.isEmpty }
        }
        
        return regex
            .matches(in: normalisedTerm, range: NSRange(location: 0, length: normalisedTerm.count))
            .compactMap { Range($0.range, in: normalisedTerm) }
            .map { normalisedTerm[$0].trimmingCharacters(in: quoteCharacterSet) }
            .map { "\"\($0)\"" }
    }
    
    // stringlint:ignore_contents
    static func standardQuotes(_ term: String) -> String {
        guard term.contains("”") || term.contains("“") else {
            return term
        }
        
        /// Apple like to use the special '""' quote characters when typing so replace them with normal ones
        return term
            .replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "“", with: "\"")
    }
    
    static func pattern(_ db: ObservingDatabase, searchTerm: String) throws -> FTS5Pattern {
        return try pattern(db, searchTerm: searchTerm, forTable: Interaction.self)
    }
    
    // stringlint:ignore_contents
    static func pattern<T>(_ db: ObservingDatabase, searchTerm: String, forTable table: T.Type) throws -> FTS5Pattern where T: TableRecord, T: ColumnExpressible {
        // Note: FTS doesn't support both prefix/suffix wild cards so don't bother trying to
        // add a prefix one
        let rawPattern: String = {
            let result: String = searchTermParts(searchTerm)
                .joined(separator: " OR ")
            
            // If the last character is a quotation mark then assume the user doesn't want to append
            // a wildcard character
            guard !standardQuotes(searchTerm).hasSuffix("\"") else { return result }
            
            return "\(result)*"
        }()
        let fallbackTerm: String = "\(searchSafeTerm(searchTerm))*"
        
        /// There are cases where creating a pattern can fail, we want to try and recover from those cases
        /// by failling back to simpler patterns if needed
        return try {
            if let pattern: FTS5Pattern = try? db.makeFTS5Pattern(rawPattern: rawPattern, forTable: table) {
                return pattern
            }
            
            if let pattern: FTS5Pattern = try? db.makeFTS5Pattern(rawPattern: fallbackTerm, forTable: table) {
                return pattern
            }
            
            return try FTS5Pattern(matchingAnyTokenIn: fallbackTerm) ?? { throw StorageError.invalidSearchPattern }()
        }()
    }
    
    static func ranges(
        for searchText: String,
        in content: String
    ) -> [NSRange] {
        if content.isEmpty || searchText.isEmpty { return [] }
        
        let parts: [String] = {
            let key: NSString = searchText as NSString
            if let cacheHit: SearchTermParts = searchTermPartCache.object(forKey: key) {
                return cacheHit.parts
            }
            
            /// The search logic only finds results that start with the term so we use the regex below to ensure we only highlight those cases
            let parts: [String] = GlobalSearch
                .searchTermParts(searchText)
                .map { part in
                    (part.hasPrefix("\"") && part.hasSuffix("\"") ?
                        part.trimmingCharacters(in: quoteCharacterSet) :
                        part
                    )
                }

            searchTermPartCache.setObject(SearchTermParts(parts), forKey: key)
            return parts
        }()
        
        let nsContent: NSString = content as NSString   /// For O(1) indexing and direct `NSRange` usage
        let contentLength: Int = nsContent.length
        var allMatches: [NSRange] = []
        allMatches.reserveCapacity(4)  // Estimate
        
        for part in parts {
            var searchRange: NSRange = NSRange(location: 0, length: contentLength)
            
            while true {
                let matchRange: NSRange = nsContent.range(of: part, options: rangeOptions, range: searchRange)
                
                guard matchRange.location != NSNotFound else { break }
                
                let isStartOfWord: Bool = {
                    if matchRange.location == 0 { return true }
                    
                    /// If the character before is a letter or number then we are inside a word (Invalid), otherwise (space,
                    /// punctuation, etc), we are at the start of a word (Valid)
                    let charBefore: unichar = nsContent.character(at: matchRange.location - 1)
                    
                    return !alphanumericSet.characterIsMember(charBefore)
                }()
                
                /// If the match is at the start of the word then we can add it
                if isStartOfWord {
                    allMatches.append(matchRange)
                }
                
                /// We can now jump to the end of the match, if the same part has another match within the word (eg. "na" in
                /// "banana") then the `isStartOfWord` check will prevent that from being added
                let nextStart: Int = matchRange.location + matchRange.length
                if nextStart >= contentLength { break }
                searchRange = NSRange(location: nextStart, length: contentLength - nextStart)
            }
        }
        
        /// If we 0 or 1 match then we can just return now
        guard allMatches.count <= 1 else { return allMatches }
        
        /// We want to match the longest parts if there were overlaps (eg. match "Testing" before "Test" if both are present)
        ///
        /// Sort by location ASC, then length DESC
        if allMatches.count > 1 {
            allMatches.sort { lhs, rhs in
                if lhs.location != rhs.location {
                    return lhs.location < rhs.location
                }
                
                return lhs.length > rhs.length
            }
        }
        
        /// Remove overlaps
        var maxIndexProcessed: Int = 0
        var results: [NSRange] = []
        results.reserveCapacity(allMatches.count)
        
        for range in allMatches {
            if range.location >= maxIndexProcessed {
                results.append(range)
                maxIndexProcessed = (range.location + range.length)
            }
        }
        
        return results
    }
    
    static func highlightSearchText(
        searchText: String,
        content: String,
        authorName: String? = nil
    ) -> String {
        guard !content.isEmpty, content != "noteToSelf".localized() else {
            if let authorName: String = authorName, !authorName.isEmpty {
                return "messageSnippetGroup"
                    .put(key: "author", value: authorName)
                    .put(key: "message_snippet", value: content)
                    .localized()
            }
            
            return content
        }
        
        /// Bold each part of the searh term which matched
        var ranges: [NSRange] = GlobalSearch.ranges(for: searchText, in: content)
        let mutableResult: NSMutableString = NSMutableString(string: content)
        
        // stringlint:ignore_contents
        if !ranges.isEmpty {
            /// Sort the ranges so they are in reverse order (that way we can insert bold tags without messing up the ranges
            ranges.sort { $0.lowerBound > $1.lowerBound }
            
            for range in ranges {
                mutableResult.insert("</b><faded>", at: range.upperBound)
                mutableResult.insert("</faded><b>", at: range.lowerBound)
            }
        }
        
        /// Wrap entire result in `<faded>` tags (since we want everything else to be faded)
        ///
        /// **Note:** We do this even when `ranges` is empty because we want anything that doesn't contain a match to also
        /// be faded
        mutableResult.insert("<faded>", at: 0)  // stringlint:ignore
        mutableResult.append("</faded>")        // stringlint:ignore
        
        /// If we don't have an `authorName` then we can finish here
        guard let authorName: String = authorName, !authorName.isEmpty else {
            return (mutableResult as String)
        }
        
        /// Since it was provided we want to include the author name
        return "messageSnippetGroup"
            .put(key: "author", value: authorName)
            .put(key: "message_snippet", value: (mutableResult as String))
            .localized()
    }
}

public extension ConversationDataHelper {
    static func updateCacheForSearchResults(
        _ db: ObservingDatabase,
        currentCache: ConversationDataCache,
        conversationResults: [GlobalSearch.ConversationSearchResult],
        messageResults: [GlobalSearch.MessageSearchResult],
        using dependencies: Dependencies
    ) throws -> ConversationDataCache {
        /// Find which ids need to be fetched (no need to re-fetch values we already have in the cache as they are very unlikely to
        /// have changed during this search session)
        let threadIds: Set<String> = Set(conversationResults.map { $0.id })
            .subtracting(currentCache.threads.keys)
        let messageThreadIds: Set<String> = Set(messageResults.map { $0.threadId })
            .subtracting(currentCache.threads.keys)
        let interactionIds: Set<Int64> = Set(messageResults.map { $0.interactionId })
            .subtracting(currentCache.interactions.keys)
        let allThreadIds: Set<String> = threadIds.union(messageThreadIds)
        
        return try ConversationDataHelper.fetchFromDatabase(
            db,
            requirements: FetchRequirements(
                requireAuthMethodFetch: false,
                requiresMessageRequestCountUpdate: false,
                requiresInitialUnreadInteractionInfo: false,
                requireRecentReactionEmojiUpdate: false,
                threadIdsNeedingFetch: allThreadIds,
                threadIdsNeedingInteractionStats: messageThreadIds,
                interactionIdsNeedingFetch: interactionIds
            ),
            currentCache: currentCache,
            using: dependencies
        )
    }
    
    static func processSearchResults(
        cache: ConversationDataCache,
        searchText: String,
        conversationResults: [GlobalSearch.ConversationSearchResult],
        messageResults: [GlobalSearch.MessageSearchResult],
        userSessionId: SessionId,
        using dependencies: Dependencies
    ) -> (conversations: [ConversationInfoViewModel], messages: [ConversationInfoViewModel]) {
        let conversations: [ConversationInfoViewModel] = conversationResults.compactMap { result -> ConversationInfoViewModel? in
            guard let thread: SessionThread = cache.thread(for: result.id) else { return nil }
            
            return ConversationInfoViewModel(
                thread: thread,
                dataCache: cache,
                searchText: searchText,
                using: dependencies
            )
        }
        let messages: [ConversationInfoViewModel] = messageResults.compactMap { result -> ConversationInfoViewModel? in
            guard
                let thread: SessionThread = cache.thread(for: result.threadId),
                cache.interaction(for: result.interactionId) != nil
            else { return nil }
            
            return ConversationInfoViewModel(
                thread: thread,
                dataCache: cache,
                targetInteractionId: result.interactionId,
                searchText: searchText,
                using: dependencies
            )
        }
        
        return (conversations, messages)
    }
    
    static func generateCacheForDefaultContacts(
        _ db: ObservingDatabase,
        contactIds: [String],
        using dependencies: Dependencies
    ) throws -> ConversationDataCache {
        return try ConversationDataHelper.fetchFromDatabase(
            db,
            requirements: FetchRequirements(
                requireAuthMethodFetch: false,
                requiresMessageRequestCountUpdate: false,
                requiresInitialUnreadInteractionInfo: false,
                requireRecentReactionEmojiUpdate: false,
                contactIdsNeedingFetch: Set(contactIds)
            ),
            currentCache: ConversationDataCache(
                userSessionId: dependencies[cache: .general].sessionId,
                context: ConversationDataCache.Context(
                    source: .searchResults,
                    requireFullRefresh: false,
                    requireAuthMethodFetch: false,
                    requiresMessageRequestCountUpdate: false,
                    requiresInitialUnreadInteractionInfo: false,
                    requireRecentReactionEmojiUpdate: false
                )
            ),
            using: dependencies
        )
    }
    
    static func processDefaultContacts(
        cache: ConversationDataCache,
        contactIds: [String],
        userSessionId: SessionId,
        using dependencies: Dependencies
    ) -> [ConversationInfoViewModel] {
        return contactIds.compactMap { contactId -> ConversationInfoViewModel? in
            guard cache.contact(for: contactId) != nil else { return nil }
            
            /// If there isn't a thread for the contact (because it's hidden) then we need to create one and insert it into a temporary
            /// cache in order to build the view model
            let thread: SessionThread = (cache.thread(for: contactId) ?? SessionThread(
                id: contactId,
                variant: .contact,
                creationDateTimestamp: dependencies.dateNow.timeIntervalSince1970,
                shouldBeVisible: false
            ))
            
            var tempCache: ConversationDataCache = cache
            tempCache.insert(thread)
            
            return ConversationInfoViewModel(
                thread: thread,
                dataCache: tempCache,
                using: dependencies
            )
        }
    }
}

// MARK: - ConversationSearchResult

public extension GlobalSearch {
    struct ConversationSearchResult: Decodable, FetchableRecord, ColumnExpressible {
        public typealias Columns = CodingKeys
        public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
            case rank
            case id
        }
        
        public let rank: Double
        public let id: String
        
        public static func defaultContactsQuery(userSessionId: SessionId) -> SQLRequest<ConversationSearchResult> {
            let contact: TypedTableAlias<Contact> = TypedTableAlias()
            
            return """
                SELECT
                    100 AS rank,
                    \(contact[.id]) AS id
                FROM \(Contact.self)
                WHERE \(contact[.isBlocked]) = false
            """
        }
        
        public static func noteToSelfOnlyQuery(userSessionId: SessionId) -> SQLRequest<ConversationSearchResult> {
            let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
            
            return """
                SELECT
                    100 AS rank,
                    \(thread[.id]) AS id
                FROM \(SessionThread.self)
                WHERE \(SQL("\(thread[.id]) = \(userSessionId.hexString)"))
            """
        }
        
        /// This function does an FTS search against threads and their contacts to find any which contain the pattern
        ///
        /// **Note:** Unfortunately the FTS search only allows for a single pattern match per query which means we
        /// need to combine the results of **all** of the following potential matches as unioned queries:
        /// - Contact thread contact nickname
        /// - Contact thread contact name
        /// - Group name
        /// - Group member nickname
        /// - Group member name
        /// - Community name
        /// - "Note to self" text match
        /// - Hidden contact nickname
        /// - Hidden contact name
        ///
        /// **Note 2:** Since the "Hidden Contact" records don't have associated threads the `rowId` value in the
        /// returned results will always be `-1` for those results
        public static func query(
            userSessionId: SessionId,
            pattern: FTS5Pattern,
            searchTerm: String
        ) -> SQLRequest<ConversationSearchResult> {
            let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
            let contactProfile: TypedTableAlias<Profile> = TypedTableAlias()
            let closedGroup: TypedTableAlias<ClosedGroup> = TypedTableAlias()
            let groupMember: TypedTableAlias<GroupMember> = TypedTableAlias()
            let groupMemberProfile: TypedTableAlias<Profile> = TypedTableAlias(
                name: "groupMemberProfile"  // stringlint:ignore
            )
            let openGroup: TypedTableAlias<OpenGroup> = TypedTableAlias()
            let contact: TypedTableAlias<Contact> = TypedTableAlias()
            let profileFullTextSearch: TypedTableAlias<Profile.FullTextSearch> = TypedTableAlias(
                name: Profile.fullTextSearchTableName
            )
            let closedGroupFullTextSearch: TypedTableAlias<ClosedGroup.FullTextSearch> = TypedTableAlias(
                name: ClosedGroup.fullTextSearchTableName
            )
            let openGroupFullTextSearch: TypedTableAlias<OpenGroup.FullTextSearch> = TypedTableAlias(
                name: OpenGroup.fullTextSearchTableName
            )
            
            let noteToSelfLiteral: SQL = SQL(stringLiteral: "noteToSelf".localized().lowercased())
            let searchTermLiteral: SQL = SQL(stringLiteral: searchTerm.lowercased())
            
            var sqlQuery: SQL = ""
            
            // MARK: - Contact Thread Searches
            
            // Contact nickname search
            sqlQuery += """
                SELECT
                    IFNULL(\(Column.rank), 100) AS rank,
                    \(thread[.id]) AS id
                FROM \(SessionThread.self)
                JOIN \(contactProfile) ON \(contactProfile[.id]) = \(thread[.id])
                JOIN \(profileFullTextSearch) ON (
                    \(profileFullTextSearch[.rowId]) = \(contactProfile[.rowId]) AND
                    \(profileFullTextSearch[.nickname]) MATCH \(pattern)
                )
                WHERE (
                    \(SQL("\(thread[.variant]) = \(SessionThread.Variant.contact)")) AND
                    \(SQL("\(thread[.id]) != \(userSessionId.hexString)"))
                )
                
                UNION ALL
                
                SELECT
                    IFNULL(\(Column.rank), 100) AS rank,
                    \(thread[.id]) AS id
                FROM \(SessionThread.self)
                JOIN \(contactProfile) ON \(contactProfile[.id]) = \(thread[.id])
                JOIN \(profileFullTextSearch) ON (
                    \(profileFullTextSearch[.rowId]) = \(contactProfile[.rowId]) AND
                    \(profileFullTextSearch[.name]) MATCH \(pattern)
                )
                WHERE (
                    \(SQL("\(thread[.variant]) = \(SessionThread.Variant.contact)")) AND
                    \(SQL("\(thread[.id]) != \(userSessionId.hexString)"))
                )
            """
            
            // MARK: - Group Searches
            
            // Group name search
            sqlQuery += """
                
                UNION ALL
                
                SELECT
                    IFNULL(\(Column.rank), 100) AS rank,
                    \(thread[.id]) AS id
                FROM \(SessionThread.self)
                JOIN \(ClosedGroup.self) ON \(closedGroup[.threadId]) = \(thread[.id])
                JOIN \(closedGroupFullTextSearch) ON (
                    \(closedGroupFullTextSearch[.rowId]) = \(closedGroup[.rowId]) AND
                    \(closedGroupFullTextSearch[.name]) MATCH \(pattern)
                )
                WHERE (
                    \(SQL("\(thread[.variant]) = \(SessionThread.Variant.legacyGroup)")) OR
                    \(SQL("\(thread[.variant]) = \(SessionThread.Variant.group)"))
                )
            """
            
            // Group member nickname search
            sqlQuery += """
                
                UNION ALL
                
                SELECT
                    IFNULL(\(Column.rank), 100) AS rank,
                    \(thread[.id]) AS id
                FROM \(SessionThread.self)
                JOIN \(ClosedGroup.self) ON \(closedGroup[.threadId]) = \(thread[.id])
                JOIN \(GroupMember.self) ON (
                    \(SQL("\(groupMember[.role]) = \(GroupMember.Role.standard)")) AND
                    \(groupMember[.groupId]) = \(thread[.id])
                )
                JOIN \(groupMemberProfile) ON \(groupMemberProfile[.id]) = \(groupMember[.profileId])
                JOIN \(profileFullTextSearch) ON (
                    \(profileFullTextSearch[.rowId]) = \(groupMemberProfile[.rowId]) AND
                    \(profileFullTextSearch[.nickname]) MATCH \(pattern)
                )
                WHERE (
                    \(SQL("\(thread[.variant]) = \(SessionThread.Variant.legacyGroup)")) OR
                    \(SQL("\(thread[.variant]) = \(SessionThread.Variant.group)"))
                )
            """
            
            // Group member name search
            sqlQuery += """
                
                UNION ALL
                
                SELECT
                    IFNULL(\(Column.rank), 100) AS rank,
                    \(thread[.id]) AS id
                FROM \(SessionThread.self)
                JOIN \(ClosedGroup.self) ON \(closedGroup[.threadId]) = \(thread[.id])
                JOIN \(GroupMember.self) ON (
                    \(SQL("\(groupMember[.role]) = \(GroupMember.Role.standard)")) AND
                    \(groupMember[.groupId]) = \(thread[.id])
                )
                JOIN \(groupMemberProfile) ON \(groupMemberProfile[.id]) = \(groupMember[.profileId])
                JOIN \(profileFullTextSearch) ON (
                    \(profileFullTextSearch[.rowId]) = \(groupMemberProfile[.rowId]) AND
                    \(profileFullTextSearch[.name]) MATCH \(pattern)
                )
                WHERE (
                    \(SQL("\(thread[.variant]) = \(SessionThread.Variant.legacyGroup)")) OR
                    \(SQL("\(thread[.variant]) = \(SessionThread.Variant.group)"))
                )
            """
            
            // MARK: - Community Search
            
            sqlQuery += """
                
                UNION ALL
                
                SELECT
                    IFNULL(\(Column.rank), 100) AS rank,
                    \(thread[.id]) AS id
                FROM \(SessionThread.self)
                JOIN \(OpenGroup.self) ON \(openGroup[.threadId]) = \(thread[.id])
                JOIN \(openGroupFullTextSearch) ON (
                    \(openGroupFullTextSearch[.rowId]) = \(openGroup[.rowId]) AND
                    \(openGroupFullTextSearch[.name]) MATCH \(pattern)
                )
                WHERE \(SQL("\(thread[.variant]) = \(SessionThread.Variant.community)"))
            """
            
            // MARK: - Note to Self Searches
            
            // "Note to Self" literal match
            sqlQuery += """
                
                UNION ALL
                
                SELECT
                    100 AS rank,
                    \(thread[.id]) AS id
                FROM \(SessionThread.self)
                WHERE (
                    \(SQL("\(thread[.id]) = \(userSessionId.hexString)")) AND
                    '\(noteToSelfLiteral)' LIKE '%\(searchTermLiteral)%'
                )
            """
            
            // Note to self nickname search
            sqlQuery += """
                
                UNION ALL
                
                SELECT
                    IFNULL(\(Column.rank), 100) AS rank,
                    \(thread[.id]) AS id
                FROM \(SessionThread.self)
                JOIN \(contactProfile) ON \(contactProfile[.id]) = \(thread[.id])
                JOIN \(profileFullTextSearch) ON (
                    \(profileFullTextSearch[.rowId]) = \(contactProfile[.rowId]) AND
                    \(profileFullTextSearch[.nickname]) MATCH \(pattern)
                )
                WHERE \(SQL("\(thread[.id]) = \(userSessionId.hexString)"))
            """
            
            // Note to self name search
            sqlQuery += """
                
                UNION ALL
                
                SELECT
                    IFNULL(\(Column.rank), 100) AS rank,
                    \(thread[.id]) AS id
                FROM \(SessionThread.self)
                JOIN \(contactProfile) ON \(contactProfile[.id]) = \(thread[.id])
                JOIN \(profileFullTextSearch) ON (
                    \(profileFullTextSearch[.rowId]) = \(contactProfile[.rowId]) AND
                    \(profileFullTextSearch[.name]) MATCH \(pattern)
                )
                WHERE \(SQL("\(thread[.id]) = \(userSessionId.hexString)"))
            """
            
            // MARK: - Hidden Contact Searches
            
            // Hidden contact nickname
            sqlQuery += """
                
                UNION ALL
                
                SELECT
                    IFNULL(\(Column.rank), 100) AS rank,
                    \(contact[.id]) AS id
                FROM \(Contact.self)
                JOIN \(contactProfile) ON \(contactProfile[.id]) = \(contact[.id])
                JOIN \(profileFullTextSearch) ON (
                    \(profileFullTextSearch[.rowId]) = \(contactProfile[.rowId]) AND
                    \(profileFullTextSearch[.nickname]) MATCH \(pattern)
                )
                WHERE NOT EXISTS (
                    SELECT 1 FROM \(SessionThread.self)
                    WHERE \(thread[.id]) = \(contact[.id])
                )
            """
            
            // Hidden contact name
            sqlQuery += """
                
                UNION ALL
                
                SELECT
                    IFNULL(\(Column.rank), 100) AS rank,
                    \(contact[.id]) AS id
                FROM \(Contact.self)
                JOIN \(contactProfile) ON \(contactProfile[.id]) = \(contact[.id])
                JOIN \(profileFullTextSearch) ON (
                    \(profileFullTextSearch[.rowId]) = \(contactProfile[.rowId]) AND
                    \(profileFullTextSearch[.name]) MATCH \(pattern)
                )
                WHERE NOT EXISTS (
                    SELECT 1 FROM \(SessionThread.self)
                    WHERE \(thread[.id]) = \(contact[.id])
                )
            """
            
            // Final grouping and ordering
            let finalQuery: SQL = """
                WITH ranked_results AS (
                    \(sqlQuery)
                ) 
                SELECT r.rank, r.id
                FROM ranked_results AS r
                LEFT JOIN \(ClosedGroup.self) ON \(closedGroup[.threadId]) = r.id
                LEFT JOIN \(OpenGroup.self) ON \(openGroup[.threadId]) = r.id
                GROUP BY r.id
                ORDER BY
                    r.rank,
                    CASE WHEN r.id = \(userSessionId.hexString) THEN 0 ELSE 1 END,
                    COALESCE(\(closedGroup[.name]), ''),
                    COALESCE(\(openGroup[.name]), ''),
                    r.id
                LIMIT \(SQL("\(searchResultsLimit)"))
            """
            
            return SQLRequest<ConversationSearchResult>(literal: finalQuery, cached: false)
        }
    }
}

// MARK: - MessageSearchResult

public extension GlobalSearch {
    struct MessageSearchResult: Decodable, FetchableRecord, ColumnExpressible {
        public typealias Columns = CodingKeys
        public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
            case rank
            case interactionId
            case threadId
        }
        
        public let rank: Double
        public let interactionId: Int64
        public let threadId: String
        
        public static func query(
            userSessionId: SessionId,
            pattern: FTS5Pattern
        ) -> SQLRequest<MessageSearchResult> {
            let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
            let interactionFullTextSearch: TypedTableAlias<Interaction.FullTextSearch> = TypedTableAlias(
                name: Interaction.fullTextSearchTableName
            )
            
            return """
                SELECT
                    \(Column.rank) AS rank,
                    \(interaction[.id]) AS interactionId,
                    \(interaction[.threadId]) AS threadId
                FROM \(Interaction.self)
                JOIN \(interactionFullTextSearch) ON (
                    \(interactionFullTextSearch[.rowId]) = \(interaction[.rowId]) AND
                    \(interactionFullTextSearch[.body]) MATCH \(pattern)
                )
                ORDER BY \(Column.rank), \(interaction[.timestampMs].desc)
                LIMIT \(SQL("\(searchResultsLimit)"))
            """
        }
    }
}
