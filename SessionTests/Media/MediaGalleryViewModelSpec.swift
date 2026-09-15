// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import Quick
import Nimble
import SessionMessagingKit
import SessionUtilitiesKit

@testable import Session

/// Records the isolation each `albumData` write actually ran under. The override inherits whatever isolation
/// `updateAlbumData` declares, so this compiles either way and reports `false` if the isolation is dropped
private class IsolationProbeViewModel: MediaGalleryViewModel {
    nonisolated(unsafe) var writesOnMainThread: [Bool] = []
    
    override func updateAlbumData(_ updatedData: [MediaGalleryViewModel.Item], for interactionId: Int64) {
        writesOnMainThread.append(Thread.isMainThread)
        super.updateAlbumData(updatedData, for: interactionId)
    }
}

class MediaGalleryViewModelSpec: AsyncSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies()
        @TestState var mockStorage: Storage! = try! Storage.createForTesting(using: dependencies)
        @TestState var viewModel: IsolationProbeViewModel!
        
        beforeEach {
            dependencies.set(singleton: .storage, to: mockStorage)
            try await mockStorage.perform(migrations: SNMessagingKit.migrations)
            
            viewModel = IsolationProbeViewModel(
                threadId: "TestId",
                threadVariant: .contact,
                isPagedData: false,
                mediaType: .media,
                using: dependencies
            )
        }
        
        // MARK: - a MediaGalleryViewModel
        describe("a MediaGalleryViewModel") {
            // MARK: -- when caching album data from a detached task
            context("when caching album data from a detached task") {
                // MARK: ---- writes the album cache on the main actor
                it("writes the album cache on the main actor") {
                    /// `prefetchAdjacentAlbums` reaches `loadAndCacheAlbumData` through `Task.detached`, which inherits
                    /// no actor — so this is the isolation boundary the full-screen viewer's album cache is written across
                    await Task.detached { [viewModel] in
                        _ = await viewModel?.loadAndCacheAlbumData(for: 1, in: "TestId")
                    }.value
                    
                    expect(viewModel.writesOnMainThread).to(equal([true]))
                }
            }
        }
    }
}
