// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import DifferenceKit
import SignalUtilitiesKit
import SessionMessagingKit
import SessionUtilitiesKit

public class ThreadPickerViewModel {
    // MARK: - Initialization
    
    public let dependencies: Dependencies
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
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
                    let wasKickedFromGroup: Bool = (
                        threadViewModel.threadVariant == .group &&
                        LibSession.wasKickedFromGroup(
                            groupSessionId: SessionId(.group, hex: threadViewModel.threadId),
                            using: dependencies
                        )
                    )
                    let groupIsDestroyed: Bool = (
                        threadViewModel.threadVariant == .group &&
                        LibSession.groupIsDestroyed(
                            groupSessionId: SessionId(.group, hex: threadViewModel.threadId),
                            using: dependencies
                        )
                    )
                    
                    return threadViewModel.populatingPostQueryData(
                        db,
                        currentUserBlinded15SessionIdForThisThread: nil,
                        currentUserBlinded25SessionIdForThisThread: nil,
                        wasKickedFromGroup: wasKickedFromGroup,
                        groupIsDestroyed: groupIsDestroyed,
                        threadCanWrite: threadViewModel.determineInitialCanWriteFlag(using: dependencies),
                        using: dependencies
                    )
                }
        }
        .map { [dependencies] threads -> [SessionThreadViewModel] in
            threads.filter { $0.threadCanWrite == true }   // Exclude unwritable threads
        }
        .removeDuplicates()
        .handleEvents(didFail: { Log.error("Observation failed with error: \($0)") })
    
    // MARK: - Functions
    
    public func updateData(_ updatedData: [SessionThreadViewModel]) {
        self.viewData = updatedData
    }
}
