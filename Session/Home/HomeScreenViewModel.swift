// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import DifferenceKit
import SignalUtilitiesKit
import SessionMessagingKit
import SessionUtilitiesKit

public class HomeScreenViewModel: ObservableObject {
    @Published public var dataModel: HomeScreenDataModel
    
    private var dataChangeObservable: DatabaseCancellable? {
        didSet { oldValue?.cancel() }   // Cancel the old observable if there was one
    }
    private var hasLoadedInitialStateData: Bool = false
    private var hasLoadedInitialThreadData: Bool = false
    private var isLoadingMore: Bool = false
    private var isAutoLoadingNextPage: Bool = false
    
    init(using dependencies: Dependencies, onReceivedInitialChange: (() -> ())? = nil) {
        self.dataModel = HomeScreenDataModel(using: dependencies)
        self.startObservingChanges(onReceivedInitialChange: onReceivedInitialChange)
    }
    
    // MARK: - Updating
    
    public func startObservingChanges(didReturnFromBackground: Bool = false, onReceivedInitialChange: (() -> ())? = nil) {
        guard dataChangeObservable == nil else { return }
        
        var runAndClearInitialChangeCallback: (() -> ())? = nil
        
        runAndClearInitialChangeCallback = { [weak self] in
            guard self?.hasLoadedInitialStateData == true && self?.hasLoadedInitialThreadData == true else { return }
            
            onReceivedInitialChange?()
            runAndClearInitialChangeCallback = nil
        }
        
        dataChangeObservable = Storage.shared.start(
            dataModel.observableState,
            onError: { _ in },
            onChange: { [weak self] state in
                // The default scheduler emits changes on the main thread
                self?.dataModel.state = state
                runAndClearInitialChangeCallback?()
            }
        )
        
        self.dataModel.onThreadChange = { [weak self] updatedThreadData, changeset in
            self?.dataModel.threadData = updatedThreadData
            runAndClearInitialChangeCallback?()
        }
        
        // Note: When returning from the background we could have received notifications but the
        // PagedDatabaseObserver won't have them so we need to force a re-fetch of the current
        // data to ensure everything is up to date
        if didReturnFromBackground {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.dataModel.pagedDataObserver?.reload()
            }
        }
    }
    
    public func stopObservingChanges() {
        // Stop observing database changes
        self.dataChangeObservable = nil
        self.dataModel.onThreadChange = nil
    }
    
//    private func autoLoadNextPageIfNeeded() {
//        guard
//            self.hasLoadedInitialThreadData &&
//                !self.isAutoLoadingNextPage &&
//                !self.isLoadingMore
//        else { return }
//        
//        self.isAutoLoadingNextPage = true
//        
//        DispatchQueue.main.asyncAfter(deadline: .now() + PagedData.autoLoadNextPageDelay) { [weak self] in
//            self?.isAutoLoadingNextPage = false
//            
//            // Note: We sort the headers as we want to prioritise loading newer pages over older ones
//            let sections: [(HomeViewModel.Section, CGRect)] = (self?.dataModel.threadData
//                .enumerated()
//                .map { index, section in (section.model, (self?.tableView.rectForHeader(inSection: index) ?? .zero)) })
//                .defaulting(to: [])
//            let shouldLoadMore: Bool = sections
//                .contains { section, headerRect in
//                    section == .loadMore &&
//                    headerRect != .zero &&
//                    (self?.tableView.bounds.contains(headerRect) == true)
//                }
//            
//            guard shouldLoadMore else { return }
//            
//            self?.isLoadingMore = true
//            
//            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
//                self?.viewModel.pagedDataObserver?.load(.pageAfter)
//            }
//        }
//    }
}
