// Copyright © 2026 Session Technology Foundation. All rights reserved.

import UIKit
import Photos
import Combine
import Quick
import Nimble
import SessionUtilitiesKit
import TestUtilities

@testable import Session

class PhotoCollectionPickerViewModelSpec: AsyncSpec {
    override class func spec() {
        @TestState var dependencies: TestDependencies! = TestDependencies()
        
        // MARK: - a PhotoCollectionPickerViewModel
        describe("a PhotoCollectionPickerViewModel") {
            // MARK: -- does not fetch the albums on the thread that creates it
            it("does not fetch the albums on the thread that creates it") {
                /// The image picker creates this on the main thread as it appears
                let library: SlowPhotoLibrary = SlowPhotoLibrary()
                let start: CFTimeInterval = CACurrentMediaTime()
                let viewModel: PhotoCollectionPickerViewModel = PhotoCollectionPickerViewModel(
                    library: library,
                    using: dependencies,
                    onCollectionSelected: { _ in }
                )
                let duration: CFTimeInterval = (CACurrentMediaTime() - start)
                print("[PhotoCollectionPickerViewModelSpec] init took \(Int(duration * 1000))ms with a 1s album fetch")
                
                expect(duration).to(beLessThan(0.5))
                await expect(library.fetchCount).toEventually(equal(1), timeout: .seconds(3))
                expect(viewModel.title).toNot(beEmpty())
            }
            
            // MARK: -- does not fetch album contents when the list is shown again
            it("does not fetch album contents when the list is shown again") {
                /// The picker keeps this view model and resubscribes on main each time the album list appears
                let collections: [SlowContentsCollection] = (0..<5).map {
                    SlowContentsCollection(id: "\($0)", collection: PHAssetCollection())
                }
                let library: SlowPhotoLibrary = SlowPhotoLibrary(collections: collections)
                let viewModel: PhotoCollectionPickerViewModel = await MainActor.run { [dependencies] in
                    PhotoCollectionPickerViewModel(library: library, using: dependencies, onCollectionSelected: { _ in })
                }
                await expect(collections.map(\.contentsCount).reduce(0, +)).toEventually(equal(5), timeout: .seconds(5))
                
                let mainThreadContentsCount: Int = await MainActor.run {
                    var receivedSections: Bool = false
                    let cancellable: AnyCancellable = viewModel.tableDataPublisher.sink(
                        receiveCompletion: { _ in },
                        receiveValue: { _ in receivedSections = true }
                    )
                    cancellable.cancel()
                    expect(receivedSections).to(beTrue())
                    
                    return collections.map(\.mainThreadContentsCount).reduce(0, +)
                }
                
                expect(mainThreadContentsCount).to(equal(0))
            }
        }
    }
}

// MARK: - SlowPhotoLibrary

private final class SlowPhotoLibrary: PhotoLibrary, @unchecked Sendable {
    private let collections: [PhotoCollection]
    private let lock: NSLock = NSLock()
    private var _fetchCount: Int = 0
    
    var fetchCount: Int { lock.withLock { _fetchCount } }
    
    init(collections: [PhotoCollection] = []) {
        self.collections = collections
    }
    
    override func allPhotoCollections(using dependencies: Dependencies) -> [PhotoCollection] {
        Thread.sleep(forTimeInterval: 1)
        lock.withLock { _fetchCount += 1 }
        
        return collections
    }
}

// MARK: - SlowContentsCollection

private final class SlowContentsCollection: PhotoCollection, @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var _contentsCount: Int = 0
    private var _mainThreadContentsCount: Int = 0
    
    var contentsCount: Int { lock.withLock { _contentsCount } }
    var mainThreadContentsCount: Int { lock.withLock { _mainThreadContentsCount } }
    
    override func contents(using dependencies: Dependencies) -> PhotoCollectionContents {
        lock.withLock {
            _contentsCount += 1
            if Thread.isMainThread { _mainThreadContentsCount += 1 }
        }
        Thread.sleep(forTimeInterval: 0.2)
        
        return super.contents(using: dependencies)
    }
}
