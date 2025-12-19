// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import UniformTypeIdentifiers
import GRDB
import DifferenceKit
import SessionUIKit
import SignalUtilitiesKit
import SessionMessagingKit
import SessionUtilitiesKit

public class ThreadPickerViewModel {
    // MARK: - Initialization
    
    public let dependencies: Dependencies
    public let userMetadata: ExtensionHelper.UserMetadata?
    public let hasNonTextAttachment: Bool
    // FIXME: Clean up to follow proper MVVM
    @MainActor public private(set) var linkPreviewViewModels: [LinkPreviewViewModel] = []
    
    init(
        userMetadata: ExtensionHelper.UserMetadata?,
        itemProviders: [NSItemProvider]?,
        using dependencies: Dependencies
    ) {
        self.dependencies = dependencies
        self.userMetadata = userMetadata
        
        if #available(iOS 16.0, *) {
            self.hasNonTextAttachment = (itemProviders ?? []).contains { provider in
                provider.registeredContentTypes.contains { !$0.isText && $0 != .url }
            }
        }
        else {
            self.hasNonTextAttachment = (itemProviders ?? []).contains { provider in
                let types: [UTType] = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
                
                return (!types.isEmpty && types.contains { !$0.isText && $0 != .url })
            }
        }
    }
    
    // MARK: - Content
    
    /// This value is the current state of the view
    public private(set) var viewData: [ConversationInfoViewModel] = []
    
    /// This is all the data the screen needs to populate itself, please see the following link for tips to help optimise
    /// performance https://github.com/groue/GRDB.swift#valueobservation-performance
    ///
    /// **Note:** The 'trackingConstantRegion' is optimised in such a way that the request needs to be static
    /// otherwise there may be situations where it doesn't get updates, this means we can't have conditional queries
    ///
    /// **Note:** This observation will be triggered twice immediately (and be de-duped by the `removeDuplicates`)
    /// this is due to the behaviour of `ValueConcurrentObserver.asyncStartObservation` which triggers it's own
    /// fetch (after the ones in `ValueConcurrentObserver.asyncStart`/`ValueConcurrentObserver.syncStart`)
    /// just in case the database has changed between the two reads - unfortunately it doesn't look like there is a way to prevent this
    public lazy var observableViewData = ValueObservation
        .trackingConstantRegion { [dependencies] db -> ([String], ConversationDataCache) in
            var dataCache: ConversationDataCache = ConversationDataCache(
                userSessionId: dependencies[cache: .general].sessionId,
                context: ConversationDataCache.Context(
                    source: .conversationList,
                    requireFullRefresh: true,
                    requireAuthMethodFetch: false,
                    requiresMessageRequestCountUpdate: false,
                    requiresInitialUnreadInteractionInfo: false,
                    requireRecentReactionEmojiUpdate: false
                )
            )
            let fetchRequirements: ConversationDataHelper.FetchRequirements = ConversationDataHelper.determineFetchRequirements(
                for: .empty,
                currentCache: dataCache,
                itemCache: [ConversationInfoViewModel.ID: ConversationInfoViewModel](),
                loadPageEvent: .initial
            )
            
            /// Fetch any required data from the cache
            var loadResult: PagedData.LoadResult<ConversationInfoViewModel.ID> = PagedData.LoadedInfo(
                record: SessionThread.self,
                pageSize: Int.max,
                requiredJoinSQL: ConversationInfoViewModel.requiredJoinSQL,
                filterSQL: ConversationInfoViewModel.homeFilterSQL(userSessionId: dataCache.userSessionId),
                groupSQL: nil,
                orderSQL: ConversationInfoViewModel.homeOrderSQL
            ).asResult
            (loadResult, dataCache) = try ConversationDataHelper.fetchFromDatabase(
                ObservingDatabase.create(db, using: dependencies),
                requirements: fetchRequirements,
                currentCache: dataCache,
                loadResult: loadResult,
                loadPageEvent: .initial,
                using: dependencies
            )
            dataCache = try ConversationDataHelper.fetchFromLibSession(
                requirements: fetchRequirements,
                cache: dataCache,
                using: dependencies
            )
            
            return (loadResult.info.currentIds, dataCache)
        }
        .map { [dependencies, hasNonTextAttachment] threadIds, dataCache -> [ConversationInfoViewModel] in
            threadIds
                .compactMap { id in
                    guard let thread: SessionThread = dataCache.thread(for: id) else { return nil }
                    
                    return ConversationInfoViewModel(
                        thread: thread,
                        dataCache: dataCache,
                        using: dependencies
                    )
                }
                .filter {
                    $0.canWrite && (            /// Exclude unwritable threads
                        $0.canUpload == true || /// Exclude ununploadable threads unleass we only include text-based attachments
                        !hasNonTextAttachment
                    )
                }
        }
        .removeDuplicates()
        .handleEvents(didFail: { Log.error("Observation failed with error: \($0)") })
    
    // MARK: - Functions
    
    @MainActor public func didLoadLinkPreview(result: LinkPreviewViewModel.LoadResult) {
        switch result {
            case .success(let linkPreview): linkPreviewViewModels.append(linkPreview)
            default: break
        }
    }
    
    public func updateData(_ updatedData: [ConversationInfoViewModel]) {
        self.viewData = updatedData
    }
}
