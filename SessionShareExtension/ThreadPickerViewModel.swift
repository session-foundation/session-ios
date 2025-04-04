// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
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
    
    public lazy var observableViewData: AnyPublisher<([SessionThreadViewModel], StagedChangeset<[SessionThreadViewModel]>), Never> = dependencies[cache: .libSession].conversations
        .map { conversations -> [SessionThreadViewModel] in
            conversations
                .filter {
                    $0.threadIsBlocked == false &&  // Exclude blocked threads
                    $0.threadCanWrite == true       // Exclude unwritable threads
                }
        }
        .removeDuplicates()
        .withPrevious([])
        .map { (previous: [SessionThreadViewModel], current: [SessionThreadViewModel]) in
            (current, StagedChangeset(source: current, target: previous))
        }
        .eraseToAnyPublisher()
    
    // MARK: - Functions
    
    public func updateData(_ updatedData: [SessionThreadViewModel]) {
        self.viewData = updatedData
    }
}
