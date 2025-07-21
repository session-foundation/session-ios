// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUIKit

@testable import SessionMessagingKit

class MockImageDataManager: Mock<ImageDataManagerType>, ImageDataManagerType {
    func load(
        _ source: ImageDataManager.DataSource,
        onComplete: @escaping (SessionUIKit.ImageDataManager.ProcessedImageData?) -> Void)
    {
        onComplete(mock(args: ["mock", source]))
    }
    
    @discardableResult func load(_ source: ImageDataManager.DataSource) async -> SessionUIKit.ImageDataManager.ProcessedImageData? {
        return mock(args: ["mock", source])
    }
    
    func cacheImage(_ image: UIImage, for identifier: String) async {
        mockNoReturn(args: [image, identifier])
    }
    
    func cachedImage(identifier: String) async -> ImageDataManager.ProcessedImageData? {
        return mock(args: [identifier])
    }
    
    func removeImage(identifier: String) async {
        mockNoReturn(args: [identifier])
    }
    
    func clearCache() async {
        mockNoReturn()
    }
}
