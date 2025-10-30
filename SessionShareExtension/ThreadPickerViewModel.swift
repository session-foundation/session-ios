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
    @MainActor public private(set) var linkPreviewDrafts: [LinkPreviewDraft] = []
    
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
    public private(set) var viewData: [SessionThreadViewModel] = []
    
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
        .trackingConstantRegion { [dependencies] db -> [SessionThreadViewModel] in
            let userSessionId: SessionId = dependencies[cache: .general].sessionId
            
            return try SessionThreadViewModel
                .shareQuery(userSessionId: userSessionId)
                .fetchAll(db)
                .map { threadViewModel in
                    let (wasKickedFromGroup, groupIsDestroyed): (Bool, Bool) = {
                        guard threadViewModel.threadVariant == .group else { return (false, false) }
                        
                        let sessionId: SessionId = SessionId(.group, hex: threadViewModel.threadId)
                        return dependencies.mutate(cache: .libSession) { cache in
                            (
                                cache.wasKickedFromGroup(groupSessionId: sessionId),
                                cache.groupIsDestroyed(groupSessionId: sessionId)
                            )
                        }
                    }()
                    
                    return threadViewModel.populatingPostQueryData(
                        recentReactionEmoji: nil,
                        openGroupCapabilities: nil,
                        currentUserSessionIds: [userSessionId.hexString],
                        wasKickedFromGroup: wasKickedFromGroup,
                        groupIsDestroyed: groupIsDestroyed,
                        threadCanWrite: threadViewModel.determineInitialCanWriteFlag(using: dependencies),
                        threadCanUpload: threadViewModel.determineInitialCanUploadFlag(using: dependencies)
                    )
                }
        }
        .map { [dependencies, hasNonTextAttachment] threads -> [SessionThreadViewModel] in
            threads.filter {
                $0.threadCanWrite == true && (      /// Exclude unwritable threads
                    $0.threadCanUpload == true ||   /// Exclude ununploadable threads unleass we only include text-based attachments
                    !hasNonTextAttachment
                )
            }
        }
        .removeDuplicates()
        .handleEvents(didFail: { Log.error("Observation failed with error: \($0)") })
    
    // MARK: - Functions
    
    @MainActor public func didLoadLinkPreview(linkPreview: LinkPreviewDraft) {
        linkPreviewDrafts.append(linkPreview)
    }
    
    public func updateData(_ updatedData: [SessionThreadViewModel]) {
        self.viewData = updatedData
    }
}
