// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUIKit
import TestUtilities

@testable import SessionMessagingKit

class MockImageDataManager: ImageDataManagerType, Mockable {
    public var handler: MockHandler<ImageDataManagerType>
    
    required init(handler: MockHandler<ImageDataManagerType>) {
        self.handler = handler
    }
    
    required init(handlerForBuilder: any MockFunctionHandler) {
        self.handler = MockHandler(forwardingHandler: handlerForBuilder)
    }
    
    @discardableResult func load(
        _ source: ImageDataManager.DataSource
    ) async -> ImageDataManager.ProcessedImageData? {
        return handler.mock(args: [source])
    }
    
    @MainActor
    func load(
        _ source: ImageDataManager.DataSource,
        onComplete: @MainActor @escaping (ImageDataManager.ProcessedImageData?) -> Void
    ) {
        handler.mockNoReturn(args: [source])
    }
    
    func cacheImage(_ image: UIImage, for identifier: String) async {
        handler.mockNoReturn(args: [image, identifier])
    }
    
    func cachedImage(identifier: String) async -> ImageDataManager.ProcessedImageData? {
        return handler.mock(args: [identifier])
    }
    
    func removeImage(identifier: String) async {
        handler.mockNoReturn(args: [identifier])
    }
    
    func clearCache() async {
        handler.mockNoReturn()
    }
}
