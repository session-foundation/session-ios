// Copyright © 2026 Session Technology Foundation. All rights reserved.

import UIKit
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
        }
    }
}

// MARK: - SlowPhotoLibrary

private final class SlowPhotoLibrary: PhotoLibrary, @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var _fetchCount: Int = 0
    
    var fetchCount: Int { lock.withLock { _fetchCount } }
    
    override func allPhotoCollections(using dependencies: Dependencies) -> [PhotoCollection] {
        Thread.sleep(forTimeInterval: 1)
        lock.withLock { _fetchCount += 1 }
        
        return []
    }
}
