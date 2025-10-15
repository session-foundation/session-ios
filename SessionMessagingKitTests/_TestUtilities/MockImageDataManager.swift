// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUIKit

@testable import SessionMessagingKit

class MockImageDataManager: Mock<ImageDataManagerType>, ImageDataManagerType {
    @discardableResult func load(
        _ source: ImageDataManager.DataSource
    ) async -> ImageDataManager.FrameBuffer? {
        return mock(args: [source])
    }
    
    @MainActor
    func load(
        _ source: ImageDataManager.DataSource,
        onComplete: @MainActor @escaping (ImageDataManager.FrameBuffer?) -> Void
    ) {
        mockNoReturn(args: [source], untrackedArgs: [onComplete])
    }
    
    func cacheImage(_ image: UIImage, for identifier: String) async {
        mockNoReturn(args: [image, identifier])
    }
    
    func cachedImage(identifier: String) async -> ImageDataManager.FrameBuffer? {
        return mock(args: [identifier])
    }
    
    func removeImage(identifier: String) async {
        mockNoReturn(args: [identifier])
    }
    
    func clearCache() async {
        mockNoReturn()
    }
}
