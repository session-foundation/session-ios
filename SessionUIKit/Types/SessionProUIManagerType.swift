// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit

public protocol SessionProUIManagerType: Actor {
    nonisolated var currentUserIsCurrentlyPro: Bool { get }
    nonisolated var currentUserIsPro: AsyncStream<Bool> { get }
    
    nonisolated func numberOfCharactersLeft(for content: String) -> Int
    func upgradeToPro(completion: ((_ result: Bool) -> Void)?) async
    
    @discardableResult @MainActor func showSessionProCTAIfNeeded(
        _ variant: ProCTAModal.Variant,
        dismissType: Modal.DismissType,
        beforePresented: (() -> Void)?,
        afterClosed: (() -> Void)?,
        presenting: ((UIViewController) -> Void)?
    ) -> Bool
}

// MARK: - Convenience

public extension SessionProUIManagerType {
    @discardableResult @MainActor func showSessionProCTAIfNeeded(
        _ variant: ProCTAModal.Variant,
        beforePresented: (() -> Void)?,
        afterClosed: (() -> Void)?,
        presenting: ((UIViewController) -> Void)?
    ) -> Bool {
        showSessionProCTAIfNeeded(
            variant,
            dismissType: .recursive,
            beforePresented: beforePresented,
            afterClosed: afterClosed,
            presenting: presenting
        )
    }
    
    @discardableResult @MainActor func showSessionProCTAIfNeeded(
        _ variant: ProCTAModal.Variant,
        presenting: ((UIViewController) -> Void)?
    ) -> Bool {
        showSessionProCTAIfNeeded(
            variant,
            dismissType: .recursive,
            beforePresented: nil,
            afterClosed: nil,
            presenting: presenting
        )
    }
}

// MARK: - Noop

internal actor NoopSessionProUIManager: SessionProUIManagerType {
    private let isPro: Bool
    nonisolated public let currentUserIsCurrentlyPro: Bool
    nonisolated public var currentUserIsPro: AsyncStream<Bool> {
        AsyncStream(unfolding: { return self.isPro })
    }
    
    init(isPro: Bool) {
        self.isPro = isPro
        self.currentUserIsCurrentlyPro = isPro
    }
    
    nonisolated public func numberOfCharactersLeft(for content: String) -> Int { 0 }
    
    public func upgradeToPro(completion: ((_ result: Bool) -> Void)?) async {
        completion?(false)
    }
    
    @discardableResult @MainActor func showSessionProCTAIfNeeded(
        _ variant: ProCTAModal.Variant,
        dismissType: Modal.DismissType,
        beforePresented: (() -> Void)?,
        afterClosed: (() -> Void)?,
        presenting: ((UIViewController) -> Void)?
    ) -> Bool {
        return false
    }
}
