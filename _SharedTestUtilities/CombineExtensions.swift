// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionUtilitiesKit

public extension AnyPublisher {
    func sinkAndStore<C>(in storage: inout C) where C : RangeReplaceableCollection, C.Element == AnyCancellable {
        self
            .receiveOnMain(immediately: true)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { _ in }
            )
            .store(in: &storage)
    }
    
    func firstValue() -> Output? {
        var value: Output?
        
        _ = self
            .receiveOnMain(immediately: true)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { result in value = result }
            )
        
        return value
    }
}
