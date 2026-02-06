// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import ImageIO
import TestUtilities

@testable import SessionUtilitiesKit

class MockMediaDecoder: MediaDecoderType, Mockable {
    public var handler: MockHandler<MediaDecoderType>
    
    required init(handler: MockHandler<MediaDecoderType>) {
        self.handler = handler
    }
    
    required init(handlerForBuilder: any MockFunctionHandler) {
        self.handler = MockHandler(forwardingHandler: handlerForBuilder)
    }
    
    var defaultImageOptions: CFDictionary { handler.mock() }
    
    func defaultThumbnailOptions(maxDimension: CGFloat) -> CFDictionary {
        return handler.mock(args: [maxDimension])
    }
    
    func source(for url: URL) -> CGImageSource? { return handler.mock(args: [url]) }
    func source(for data: Data) -> CGImageSource? { return handler.mock(args: [data]) }
}

extension MockMediaDecoder {
    func defaultInitialSetup() async throws {
        let options: CFDictionary = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false
        ] as CFDictionary
        
        try await self.when { $0.defaultImageOptions }.thenReturn(options)
        try await self.when { $0.defaultThumbnailOptions(maxDimension: .any) }.thenReturn(options)
        
        try await self
            .when { $0.source(for: URL.any) }
            .thenReturn(CGImageSourceCreateWithData(TestConstants.validImageData as CFData, options))
        try await self
            .when { $0.source(for: Data.any) }
            .thenReturn(CGImageSourceCreateWithData(TestConstants.validImageData as CFData, options))
    }
}
