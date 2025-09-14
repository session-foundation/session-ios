// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine

public extension Publisher {
    func sinkAndStore<C>(in storage: inout C) where C: RangeReplaceableCollection, C.Element == AnyCancellable {
        self
            .subscribe(on: ImmediateScheduler.shared)
            .receive(on: ImmediateScheduler.shared)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { _ in }
            )
            .store(in: &storage)
    }
}
